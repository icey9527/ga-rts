class_name WeaponMount
extends RefCounted

## 单个炮塔（L1 模拟层，见 docs/ARCHITECTURE.md「四层与依赖方向」）。
##
## ADR-0012 机制 #11「两级火控」的下半层：火控中心（Targeting，0.1 s / 1 s 分配目标）
## 只给一个目标点，**炮塔自己高频自转**追它。所以本类不做选靶、不做索敌，
## 只回答两个问题：现在能转到哪（aim_at）、现在能不能打（can_fire）。
##
## 纯 RefCounted、不继承 Node（硬规则 2）：炮塔的"表现"（转动的炮管模型）在 T-2.3 之后
## 由表现层读 aim_direction 自己画，本类一个节点都不碰。
##
## 本类刻意不做（T-2.3 范围）：
##   - 不生成弹体、不做命中判定、不算伤害。tick() 只报"想开火"，弹体由上层生成。
##   - 不做前置量（lead）计算：leading 需要目标速度，归 T-2.3 的弹道。
##
## 确定性：所有分支都只看输入（unit / target_pos / dt），没有随机、没有时间源。

## 浮点噪声阈值（与 Unit.EPSILON 同量级）
const EPSILON := 1.0e-9

## 炮塔数据（不持有 Registry / UnitDef：mount 只认这一把武器）
var def: WeaponDef = null
## 相对舰体的偏移（米，舰体坐标系：+X 右舷 / +Y 上 / +Z 舰尾，即 -Z 为舰首）
var local_offset := Vector3.ZERO
## 当前炮口指向（**世界**方向，单位向量）
var aim_direction := Vector3.FORWARD
## 剩余冷却（秒，0 = 可以开火）
var cooldown_left := 0.0


## 世界位置：舰体坐标偏移按舰体姿态旋转后叠加到舰体位置。
## 舰体姿态只有 forward（Unit 不存完整基），所以：
##   right    = forward × up
##   up       = right × forward
##   backward = -forward（舰体 +Z 朝舰尾）
func world_position(unit: Unit) -> Vector3:
	if unit == null:
		return local_offset
	var fwd := _normalized_or(unit.forward, Unit.DEGENERATE_FORWARD)
	var right := fwd.cross(Vector3.UP)
	if right.length_squared() <= 1.0e-12:
		# 机头与 UP 共线（俯仰 ±90°）时 right 退化，兜底为世界 +X（确定性优先）
		right = Vector3.RIGHT
	else:
		right = right.normalized()
	var up := right.cross(fwd).normalized()
	return unit.position \
		+ right * local_offset.x \
		+ up * local_offset.y \
		- fwd * local_offset.z


## 炮塔位置 → 目标的方向（单位向量）。目标与本炮塔重合时返回当前指向（不动、不 NaN）。
func desired_direction(unit: Unit, target_pos: Vector3) -> Vector3:
	return _normalized_or(target_pos - world_position(unit), aim_direction)


## 当前瞄准方向与目标的夹角（**弧度**）
func aim_error(unit: Unit, target_pos: Vector3) -> float:
	return aim_direction.angle_to(desired_direction(unit, target_pos))


## 按 tracking_rate 限速把 aim_direction 朝目标转（每 tick 转角 ≤ tracking_rate × dt）。
##
## 为什么是单轴球面插值而不是像 UnitMovement.step_forward 那样分 yaw / pitch：
##   炮塔的转速是一个整机指标（tracking_rate，度/秒），不是"横向快、纵向慢"的两轴手感；
##   分成两轴限幅会让斜方向的实际转角达到 √2 倍，验收用例「每 tick 转角 ≤ rate×dt」立刻失败。
##   所以这里用一个总角速度上限，两个方向都受同一条约束。
func aim_at(unit: Unit, target_pos: Vector3, dt: float) -> void:
	if unit == null:
		push_error("[WeaponMount] aim_at(null)：忽略")
		return
	if def == null:
		push_error("[WeaponMount] def 未装配（武器表没接上），本 tick 不转炮塔")
		return
	if dt <= 0.0 or not is_finite(dt) or not target_pos.is_finite():
		return
	var desired := desired_direction(unit, target_pos)
	var max_step := def.tracking_rate_rad() * dt
	var error := aim_direction.angle_to(desired)
	if error <= max_step:
		aim_direction = desired  # 转到位就精确对齐（不留恒定小误差，否则永远差最后一丝）
		return
	var axis := aim_direction.cross(desired)
	if axis.length_squared() <= 1.0e-12:
		# 恰好 180° 反向：旋转轴不唯一。绕世界 UP 转（确定性的兜底），绝不写 NaN
		axis = Vector3.UP
	aim_direction = aim_direction.rotated(axis.normalized(), max_step).normalized()


## 现在能不能开火：冷却好了 **且** 目标在射程内 **且** 夹角 ≤ aim_tolerance。
## 距离从**炮塔位置**算，不是舰体中心 —— 4 个炮塔错开在舰体上，大船这个差值是百米的量级。
func can_fire(unit: Unit, target_pos: Vector3) -> bool:
	if unit == null or def == null:
		return false
	if cooldown_left > 0.0:
		return false
	var distance := world_position(unit).distance_to(target_pos)
	if distance > def.range:
		return false
	return aim_error(unit, target_pos) <= def.aim_tolerance_rad()


## 扣冷却（"开火"这个动作本身）。弹体 / 命中 / 伤害归 T-2.3。
func consume_cooldown() -> void:
	if def == null:
		push_error("[WeaponMount] consume_cooldown() 时 def 为空，冷却无法确定")
		return
	cooldown_left = def.cooldown


## 冷却推进（每 tick 调一次）。不越 0，避免负值累积出"免费多打几发"。
func tick_cooldown(dt: float) -> void:
	if dt <= 0.0 or not is_finite(dt):
		return
	cooldown_left = maxf(cooldown_left - dt, 0.0)


## 冷却是否已归零（= 可以开火，不含几何判定）
func is_ready() -> bool:
	return cooldown_left <= 0.0


func describe() -> String:
	return "WeaponMount(%s offset=(%.1f, %.1f, %.1f) aim=(%.3f, %.3f, %.3f) cd=%.2f)" % [
		"?" if def == null else def.id,
		local_offset.x, local_offset.y, local_offset.z,
		aim_direction.x, aim_direction.y, aim_direction.z, cooldown_left]


static func _normalized_or(value: Vector3, fallback: Vector3) -> Vector3:
	if not value.is_finite():
		return fallback
	var length_squared := value.length_squared()
	if length_squared <= 1.0e-12:
		return fallback
	return value / sqrt(length_squared)
