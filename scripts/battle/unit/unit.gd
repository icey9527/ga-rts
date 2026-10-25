class_name Unit
extends RefCounted

## 单位纯数据对象（L1 模拟层，见 docs/ARCHITECTURE.md「四层与依赖方向」）。
##
## 刻意不继承 Node、不持有场景 / 资源引用、不碰渲染：
## 模拟层必须能脱离场景单测（本类的验证场景 scenes/dev/verify_unit.tscn 里没有一栋单位节点）。
## 表现层（scripts/battle/unit/unit_view.gd）**只读** position / forward / speed，一个字段都不回写
## （硬规则 4）。
##
## 坐标系（docs/scale-and-units.md「基础约定」）：1 unit = 1 m，+Y 向上，机头朝 -Z。
## 因此默认 forward = Vector3.FORWARD = (0, 0, -1)，绕世界 +Y 的 yaw 增加朝 -X 转。
##
## 累加器（硬规则 3 / ADR-0012 机制 3）：
##   每 tick 只有 UnitMovement 写 accum_position / accum_rotation / accum_speed，
##   Simulation 在 tick 末尾调 apply_accumulators() 一次性写回并清零。
##   三个 accum_* 都是**增量**（不是目标值）：
##     accum_position —— 本 tick 的位移增量（米）
##     accum_rotation —— 本 tick 的机头旋转增量（四元数，作用在 forward 上）
##     accum_speed    —— 本 tick 的标量速度增量（m/s）
##   增量语义让"同一 tick 内多写几次"自然合并成一次位移，且 apply 幂等
##   （apply 之后 accum 已清零，再 apply 一次不会重复位移）。

## 到达判定半径（米）：距当前路径点 ≤ 该值即认为到站。原 Lua 版同值。
## 取 2 m 而不是 0：飞机不可能精确压在一点上，5 m 误差以内都算到站（验收用例 1 的上限）。
const ARRIVAL_RADIUS := 2.0

## 俯仰限幅（度）。越过 90° 机头与世界 up 共线，yaw 无定义且画面会翻跟头。
## ADR-0003 的分层高度不需要更大的俯仰角，60° 足够爬完层间距 400 m。
const MAX_PITCH_DEG := 60.0

## 退化情况的兜底方向（机头 / 期望方向退化时用）。必须确定，否则同输入两次结果不同。
const DEGENERATE_FORWARD := Vector3.FORWARD

## 浮点噪声阈值
const EPSILON := 1.0e-9

# ---------------------------------------------------------------- 身份

## 运行时唯一 ID（由 Simulation / 关卡分配，本类不改它）
var id := 0
## 机型逻辑 ID（= content/units 下的目录名）。表现层拿它去注册表换模型路径（硬规则 5）。
var def_id := ""

# ---------------------------------------------------------------- 运动状态
#
# 这三个字段只在 apply_accumulators() 里被写。除 UnitMovement（写 accum_*）与
# apply_accumulators（写这三个）以外的任何代码都不该直接改它们。

## 世界坐标（米）
var position := Vector3.ZERO
## 机头方向，单位向量，默认 -Z
var forward := DEGENERATE_FORWARD
## 标量速度（m/s，沿机头方向）。位移恒为 forward * speed * dt，绝不横移
var speed := 0.0

# ---------------------------------------------------------------- 性能参数
#
# 缺省值只是占位（一艘中速护卫舰的量级），真实数值来自 content/units/<id>/unit.tbl。
# 本卡不读表：数据装配归 T-1.6，这里只保证字段就位、量纲正确。

## 最大速度（m/s）
var max_speed := 180.0
## 加速度（m/s²）
var acceleration := 60.0
## 减速度（m/s²）。刹车曲线 sqrt(2·decel·dist) 用它
var deceleration := 80.0
## 机头水平转速上限（rad/s）
var turn_rate_yaw := deg_to_rad(30.0)
## 机头俯仰转速上限（rad/s）
var turn_rate_pitch := deg_to_rad(20.0)
## XZ 半径（米，给碰撞 / 寻路膨胀用；docs/scale-and-units.md 尺寸量级）
var radius := 20.0
## 巡航高度偏好：**相对本层中心**的偏移（米），±150 m 带内有效（ADR-0003）。
## 0 = 就在本层中心。绝对高度（-400 / 0 / +400）由层给，不在这里重复写死。
var cruise_altitude := 0.0

# ---------------------------------------------------------------- 航线

## 路径点（Y = 该层巡航高度，由 NavService 给）。空数组 = 没有航线
var route := PackedVector3Array()
## 当前要去的路径点下标
var route_index := 0
## 是否已经走完航线（走完后 route 不清空：最后一个点是"驻留点"，刹车曲线要它）
var _route_finished := false

# ---------------------------------------------------------------- 生命周期

var alive := true

# ---------------------------------------------------------------- 累加器（每 tick 由 Simulation 清零）

## 本 tick 位移增量（米）
var accum_position := Vector3.ZERO
## 本 tick 机头旋转增量
var accum_rotation := Quaternion.IDENTITY
## 本 tick 标量速度增量（m/s）
var accum_speed := 0.0

# ---------------------------------------------------------------- 诊断

## 同一 tick 内被重复积分的次数（硬规则 / 验收用例 8）。恒为 0 才是对的
var double_step_count := 0
## on_route_finished() 被调用的次数
var route_finished_count := 0
## UnitMovement 的"每 tick 一次积分"守卫。只允许 UnitMovement 置位、
## reset_accumulators() / apply_accumulators() 清零
var _movement_active := false


func _init(p_id: int = 0, p_def_id: String = "") -> void:
	id = p_id
	def_id = p_def_id


# ---------------------------------------------------------------- 累加器

## 丢弃本 tick 的累加增量（tick 开头的重置，或状态切换时清残留 —— ADR-0012）。
func reset_accumulators() -> void:
	accum_position = Vector3.ZERO
	accum_rotation = Quaternion.IDENTITY
	accum_speed = 0.0
	_movement_active = false


## 一次性把累加增量写回 position / forward / speed，**然后清零**（硬规则 3）。
## 幂等：清过零之后再调一次什么也不会发生 —— 这正是"多次写 accum 只生效一次"的保证。
func apply_accumulators() -> void:
	if accum_position != Vector3.ZERO:
		position += accum_position
	if not accum_rotation.is_equal_approx(Quaternion.IDENTITY):
		var rotated := accum_rotation * forward
		if rotated.length_squared() > EPSILON:
			forward = rotated.normalized()
		else:
			# 180° 反向时旋转轴不唯一，Quaternion(from, to) 会退化。宁可保持原机头也不写 NaN
			push_error("[Unit] id=%d 的 accum_rotation 把机头转成了零向量，保持原机头" % id)
	if accum_speed != 0.0:
		speed = maxf(speed + accum_speed, 0.0)
	reset_accumulators()


## 本 tick 是否已经积分过（调试 / 验证用例用）
func movement_active() -> bool:
	return _movement_active


# ---------------------------------------------------------------- 航线

## 装一条新航线。途中会清零累加器（状态切换不留残余速度）。
func set_route(points: PackedVector3Array) -> void:
	route = points
	route_index = 0
	_route_finished = false
	reset_accumulators()


## 清空航线（停止命令）。单位会按刹车曲线把速度收到 0，不做瞬停。
func clear_route() -> void:
	route = PackedVector3Array()
	route_index = 0
	_route_finished = false


## 期望朝向：指向当前路径点。没有航线 / 已经在站内时返回当前机头（不抖动）。
func desired_forward() -> Vector3:
	var delta := current_waypoint() - expected_position()
	var length_squared := delta.length_squared()
	if length_squared <= EPSILON:
		return forward
	return delta / sqrt(length_squared)


## 当前要去的点。走完航线后是**驻留点**（最后一个路径点），不是 position：
## 刹车曲线要靠它算剩余距离，否则到站瞬间目标消失会导致冲过头。
func current_waypoint() -> Vector3:
	if route_index < route.size():
		return route[route_index]
	if route.size() > 0:
		return route[route.size() - 1]
	return position


## 到当前路径点的剩余距离（米）
func distance_to_waypoint() -> float:
	return expected_position().distance_to(current_waypoint())


## 本 tick 累积后的位置（= 下一 tick 的真实位置）。到达判定要用它，
## 否则会"晚一 tick 才发现已经到站"，多冲一步。
func expected_position() -> Vector3:
	return position + accum_position


## 到达判定：距路径点 ≤ ARRIVAL_RADIUS 就前进到下一个。返回 true 表示有前进。
## 最后一个点也到站时置 finished 并调 on_route_finished()（只调一次）。
func advance_route() -> bool:
	if route.is_empty():
		return false
	var advanced := false
	var here := expected_position()
	while route_index < route.size():
		if here.distance_to(route[route_index]) > ARRIVAL_RADIUS:
			break
		route_index += 1
		advanced = true
	if route_index >= route.size() and not _route_finished:
		_route_finished = true
		on_route_finished()
	return advanced


## 走完航线。本卡只记录 + 打点；后续卡在这里切状态机（巡逻 / 待机 / 归队）。
## 刻意**不清空 route**：最后一点留作驻留点，刹车曲线还要用它算剩余距离。
func on_route_finished() -> void:
	route_finished_count += 1


func is_route_finished() -> bool:
	return _route_finished


## 是否有"还没走到的下一站"（走完航线后为 false）
func has_active_waypoint() -> bool:
	return route_index < route.size() and not _route_finished


# ---------------------------------------------------------------- 姿态（只读派生）

## 机头俯仰角（度，正 = 抬头）
func pitch_degrees() -> float:
	return rad_to_deg(asin(clampf(forward.y, -1.0, 1.0)))


## 机头水平朝向（度，绕世界 +Y；0 = 朝 -Z，正值朝 -X）
func yaw_degrees() -> float:
	return rad_to_deg(atan2(-forward.x, -forward.z))


func describe() -> String:
	return "Unit(id=%d def=%s pos=(%.1f, %.1f, %.1f) fwd=(%.3f, %.3f, %.3f) v=%.1f/%0.1f)" % [
		id, def_id, position.x, position.y, position.z,
		forward.x, forward.y, forward.z, speed, max_speed]
