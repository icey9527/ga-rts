class_name UnitMovement
extends RefCounted

## 飞机式移动积分器（ADR-0003 + 原 Lua 版 battle/unit/movement.lua 的 3D 化）。
##
## 无状态：所有状态都从 Unit 读，**只写 unit.accum_***，绝不直接改 position / forward / speed。
## 一条硬约束贯穿全文件：位移恒为 `forward × speed × dt`（机头方向推进）。
## 没有一处能横着平移 —— 想转弯只能靠 turn_rate 慢慢掰机头，想停只能靠减速度慢慢收速度。
##
## 每 tick 的 6 步（验收用例逐条对应）：
##   0. 到达判定（放在积分之前，见函数内注释）
##   1. 期望朝向 = 指向当前路径点（Unit.desired_forward）
##   2. 按 turn_rate 转机头：yaw / pitch 分别限角速度，俯仰钳在 ±60°（防翻跟头）
##   3. 期望速度 = min(max_speed, √(2·deceleration·dist)) × max(0.25, forward·desired)
##      —— 机头不对就减速（对齐因子最低 0.25，不是 0：完全停住的船永远转不回来）
##   4. 标量速度按 acceleration / deceleration 趋近期望速度
##   5. 位移 = forward × speed × dt
##   6. 断言：每个 unit 每 tick 只允许积分一次（unit._movement_active）
##   末尾顺带调 UnitFlight.steer_altitude()：高度通道也走同一个「一次积分」守卫，
##   保证一个 unit 的一个 tick 只有一处写 accum_position。
##
## 为什么刹车曲线是 sqrt(2·a·d)：匀减速停车的距离是 v²/(2a)，反解即 v = √(2ad)。
## 照着这条曲线收速度，理论上恰好停在路径点上；离散积分（60 Hz）的残差由 step() 里
## 最后一段"到站驻留"钳位吃掉（见 travel 的计算）。

## 期望速度的对齐因子下限（原 Lua 版 0.25）。机头背对目标时也保留 1/4 推力，
## 否则速度归零 → 无位移 → 永远转不回来（死锁）。
const MIN_ALIGNMENT_FACTOR := 0.25

## 双步保护模式。生产路径是 ASSERT；验证场景用 CAPTURE 捕获（不炸进程、不中断后续用例）。
## 这不是"关掉断言"：两种模式下第二次积分都**不会**生效，只是报告方式不同。
enum GuardMode {
	ASSERT,
	CAPTURE,
}

## 当前守护模式。默认 ASSERT = 规格要求的断言保护。
static var guard_mode := GuardMode.ASSERT


# ---------------------------------------------------------------- 主入口


## 积分一个 tick。
##
## layer_height —— 该层的中心高度（-400 / 0 / +400，ADR-0003）。本函数把它原样交给
##                 UnitFlight.steer_altitude，因此调用方不需要在两个地方各写一遍层高。
static func step(unit: Unit, dt: float, layer_height: float) -> void:
	if unit == null:
		push_error("[UnitMovement] unit 为 null，跳过本次积分")
		return
	if dt <= 0.0 or not is_finite(dt):
		push_error("[UnitMovement] dt 非法（%f），跳过本次积分" % dt)
		return
	if unit._movement_active:
		# 硬规则：每 tick 一次位移积分。第二次调用只记账，绝不重复积分。
		unit.double_step_count += 1
		if guard_mode == GuardMode.ASSERT:
			assert(false, "[UnitMovement] unit %d 在同一个 tick 内被积分了两次（每 tick 只允许一次位移积分）" % unit.id)
		return
	if not unit.alive:
		return
	unit._movement_active = true

	# 0. 到达判定放在最前面：此时 accum 还是空的（上一 tick 已 apply），
	#    用当前位置判定。若放到最后用 accum 判定，最后一步就会先冲过去再发现到站。
	unit.advance_route()

	# 1. 期望朝向 = 指向当前路径点
	var desired := unit.desired_forward()

	# 2. 转机头（yaw / pitch 分别限速）
	var next_forward := step_forward(
		unit.forward, desired, unit.turn_rate_yaw, unit.turn_rate_pitch, dt)

	# 3. 期望速度（对齐因子用**转完之后**的机头：这一 tick 实际能飞的方向）
	var dist := unit.distance_to_waypoint()
	var target_speed := desired_speed_for(unit, dist, next_forward)

	# 4. 标量速度趋近期望
	var next_speed := step_speed(
		unit.speed, target_speed, unit.acceleration, unit.deceleration, dt)

	# 5. 位移 = forward × speed × dt
	var travel := maxf(next_speed, 0.0) * dt
	if unit.is_route_finished() and travel > dist:
		# 到站驻留：只差最后一点点时按剩余距离收步，不许冲过泊位。
		# 这是刹车曲线在离散积分下的收尾项（连续解本身刚好停在点上，离散解残差 ≤ 半步），
		# 不是“瞬停”：此刻 speed 本来就已经是个位数。
		travel = maxf(dist, 0.0)
		next_speed = travel / dt

	# 累加（不是覆盖）：accum_* 是**增量**，本卡里 UnitMovement 是唯一写入者，
	# 但保持 += 语义，后续系统（分离力 / 击飞）可以在本步前后各加一份贡献。
	# 旋转用左乘（本 tick 的机动旋转叠在已有旋转之上），位移与机头因此始终一致。
	unit.accum_position += next_forward * travel
	unit.accum_rotation = rotation_between(unit.forward, next_forward) * unit.accum_rotation
	unit.accum_speed += next_speed - unit.speed

	# 6. 高度通道（ADR-0003）：同一个守卫下的一处写入，保证"一次积分"覆盖 y
	UnitFlight.steer_altitude(unit, layer_height, dt)


# ---------------------------------------------------------------- 可单测的纯函数


## 期望速度（规格签名版）= 刹车曲线 × 对齐因子，对齐因子用当前机头。
static func desired_speed(unit: Unit, dist: float) -> float:
	if unit == null:
		return 0.0
	return desired_speed_for(unit, dist, unit.forward)


## 期望速度（带朝向参数版）。heading 用转完机头后的方向，物理上更贴近实际推进方向。
##
##   刹车曲线  min(max_speed, √(2·deceleration·dist))
##   对齐因子  max(0.25, forward·desired)   —— 机头不对就减速
static func desired_speed_for(unit: Unit, dist: float, heading: Vector3) -> float:
	if unit == null:
		return 0.0
	var brake := minf(
		unit.max_speed,
		sqrt(2.0 * maxf(unit.deceleration, 0.0) * maxf(dist, 0.0)))
	var alignment := clampf(heading.dot(unit.desired_forward()), -1.0, 1.0)
	return brake * maxf(MIN_ALIGNMENT_FACTOR, alignment)


## 标量速度趋近：加速用 acceleration，减速用 deceleration，永不变负。
static func step_speed(current: float, target: float,
		accel: float, decel: float, dt: float) -> float:
	var from := maxf(current, 0.0)
	if dt <= 0.0 or not is_finite(dt):
		return from
	if target > from:
		return minf(target, from + maxf(accel, 0.0) * dt)
	if target < from:
		return maxf(target, from - maxf(decel, 0.0) * dt)
	return from


## 转机头：把 current 往 desired 掰，yaw 与 pitch 各自的角速度分别被限幅，
## 最终俯仰钳在 ±MAX_PITCH_DEG。
##
## 为什么不直接 Quaternion(current, desired).slerp(IDENTITY, t)：
## 那样 yaw 与 pitch 共用一个角速度上限，横向宽体舰与纵向爬升的手感就没法分调；
## 而且没法单独给俯仰上钳（ADR-0003 明确要求 yaw / pitch 分开）。
static func step_forward(current: Vector3, desired: Vector3,
		yaw_rate: float, pitch_rate: float, dt: float) -> Vector3:
	var from := _normalized_or(current, Unit.DEGENERATE_FORWARD)
	var to := _normalized_or(desired, from)
	if dt <= 0.0 or not is_finite(dt):
		return from

	var yaw_now := _yaw_of(from)
	var pitch_now := _pitch_of(from)
	var yaw_want := _yaw_of(to)
	var pitch_want := _pitch_of(to)

	var max_yaw := maxf(yaw_rate, 0.0) * dt
	var max_pitch := maxf(pitch_rate, 0.0) * dt
	# 绕最近的一侧转（wrapf 到 [-π, π]），否则从 179° 到 -179° 会绕一整圈
	var yaw_delta := clampf(wrapf(yaw_want - yaw_now, -PI, PI), -max_yaw, max_yaw)
	var pitch_delta := clampf(pitch_want - pitch_now, -max_pitch, max_pitch)

	var max_pitch_rad := deg_to_rad(Unit.MAX_PITCH_DEG)
	var pitch_new := clampf(pitch_now + pitch_delta, -max_pitch_rad, max_pitch_rad)
	return forward_from_angles(yaw_now + yaw_delta, pitch_new)


## yaw / pitch（弧度）→ 单位机头向量。
## yaw = 0 且 pitch = 0 时得到 (0, 0, -1)，与 docs/scale-and-units.md「-Z 为正前方」一致。
static func forward_from_angles(yaw: float, pitch: float) -> Vector3:
	var horizontal := cos(pitch)
	return Vector3(-sin(yaw) * horizontal, sin(pitch), -cos(yaw) * horizontal)


## 机头 → yaw（弧度，绕世界 +Y；0 = 朝 -Z）
static func _yaw_of(direction: Vector3) -> float:
	return atan2(-direction.x, -direction.z)


## 机头 → pitch（弧度，正 = 抬头）。机头笔直朝上/下时 asin 已钳位，不会 NaN。
static func _pitch_of(direction: Vector3) -> float:
	return asin(clampf(direction.y, -1.0, 1.0))


## from → to 的旋转增量。180° 反向时旋转轴不唯一，返回 identity（宁可不动也不写 NaN）。
static func rotation_between(from: Vector3, to: Vector3) -> Quaternion:
	var a := _normalized_or(from, Unit.DEGENERATE_FORWARD)
	var b := _normalized_or(to, a)
	if a.is_equal_approx(b):
		return Quaternion.IDENTITY
	if a.dot(b) < -0.999999:
		push_error("[UnitMovement] 机头需要 180° 反向（旋转轴不唯一），本 tick 不转向")
		return Quaternion.IDENTITY
	return Quaternion(a, b)


## 归一化；退化（零向量 / NaN）时用 fallback，保证确定性
static func _normalized_or(value: Vector3, fallback: Vector3) -> Vector3:
	if not value.is_finite():
		return fallback
	var length_squared := value.length_squared()
	if length_squared <= 1.0e-12:
		return fallback
	return value / sqrt(length_squared)
