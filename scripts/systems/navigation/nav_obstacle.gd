class_name NavObstacle
extends RefCounted

## 导航障碍物：任意 3D 物体在寻路眼里就是一根 **XZ 平面上的圆柱**（ADR-0004）。
##
## 为什么是柱体：
##   可视图算法只需要「圆心 + XZ 半径 + 上下两个高度」，多一个面都是负担。
##   柱体假设同时把"飞越"变成一行比较：单位 y 高于柱顶 → 该障碍直接不参与计算
##   （等价于原 2D 版的 z 过滤，见 ADR-0004「实现要点」）。
##
## 字段语义：
##   position   —— 柱子轴线上的任意一点。**只有 X 与 Z 参与寻路**，Y 不读：
##                 单位高度一律用 route() 传进来的 height 判定，避免"某个障碍偷偷用
##                 position.y 当高度"这类隐式依赖。
##   radius_xz  —— XZ 投影半径（飞船宽度 / 小行星半径），不是直径，也不含膨胀
##   top_y      —— 柱顶高度
##   bottom_y   —— 柱底高度
##
## 本类刻意不做：
##   - 不持有任何场景节点 / 碰撞体（导航层必须能脱离场景单测，见 ARCHITECTURE「L1 模拟层」）
##   - 不决定膨胀后的大小：膨胀 = 本半径 + 单位半径 + 余量，后半段由调用方给
##     （同一个障碍对护卫舰和对母舰的膨胀圈不一样，所以膨胀不能写死在障碍上）

## 默认安全余量（ADR-0004：膨胀半径 = 障碍 r + 单位 r + 4）
const DEFAULT_SAFETY_MARGIN := 4.0
## 几何比较容差（米）。数值边界上的"恰好相切"要算作不穿透。
const GEOMETRY_EPSILON := 1.0e-3
## 退化情况（点正好在圆心上）时用的默认推出方向，必须确定，否则同一请求两次结果不同
const DEGENERATE_DIRECTION := Vector2.RIGHT


var position := Vector3.ZERO
var radius_xz := 0.0
var top_y := 0.0
var bottom_y := 0.0


func _init(p_position: Vector3 = Vector3.ZERO, p_radius_xz: float = 0.0,
		p_top_y: float = 0.0, p_bottom_y: float = 0.0) -> void:
	setup(p_position, p_radius_xz, p_top_y, p_bottom_y)


## 复用同一个实例改参数（障碍表重建时比 new() 便宜）
func setup(p_position: Vector3, p_radius_xz: float, p_top_y: float, p_bottom_y: float) -> void:
	position = p_position
	radius_xz = maxf(p_radius_xz, 0.0)
	top_y = p_top_y
	bottom_y = p_bottom_y
	if p_radius_xz < 0.0:
		push_error("[NavObstacle] radius_xz 为负（%f），按 0 处理" % p_radius_xz)


## 该障碍在 height 高度上是否构成障碍。
##
## 判据：**严格**夹在柱底与柱顶之间。恰好等于柱顶 / 柱底算擦过（不阻挡）——
## 飞行单位贴着柱顶飞过去是合理的，把它判成阻挡会让 L2（+400）对 400 m 高的
## 障碍凭空产生一圈绕行点（见 docs/scale-and-units.md 的高度分层）。
## 数据反了（top_y <= bottom_y）视为无效障碍，不阻挡，但不静默：is_valid() 会报。
func blocks_at(height: float) -> bool:
	if top_y <= bottom_y:
		return false
	return height > bottom_y and height < top_y


## 膨胀后的 XZ 半径 = 障碍半径 + 单位半径 + 安全余量。
## 参数校验失败时按 0 处理并 push_error：宁可在验证场景里炸出来，也不静默放一辆船穿模。
func inflated_radius(unit_radius: float, margin: float = DEFAULT_SAFETY_MARGIN) -> float:
	if unit_radius < 0.0:
		push_error("[NavObstacle] unit_radius 为负（%f），按 0 处理" % unit_radius)
		unit_radius = 0.0
	if margin < 0.0:
		push_error("[NavObstacle] margin 为负（%f），按 0 处理" % margin)
		margin = 0.0
	return radius_xz + unit_radius + margin


## point 的 XZ 是否落在「圆心 + radius」的圈内。radius 是**已经膨胀过**的半径。
## 用严格小于 + 容差：正好落在边界上的点（可视图的方位节点）不算在圈内。
func contains_xz(point: Vector3, radius: float) -> bool:
	if radius <= 0.0:
		return false
	var dx := point.x - position.x
	var dz := point.z - position.z
	var r := radius - GEOMETRY_EPSILON
	return dx * dx + dz * dz < r * r


## 把落在膨胀圈内的点沿**径向**推到圈外（沿用原版做法，ADR-0004）。
## 推完 Y 不变：高度由调用方（该层巡航高度）决定，本方法不碰。
## 点正好在圆心时没有径向可言，用确定的 DEGENERATE_DIRECTION 兜底，
## 保证同一请求两次调用结果完全一致（验证用例 8）。
func push_outward_xz(point: Vector3, radius: float) -> Vector3:
	var dx := point.x - position.x
	var dz := point.z - position.z
	var r := maxf(radius, 0.0)
	var distance := sqrt(dx * dx + dz * dz)
	if distance < GEOMETRY_EPSILON:
		return Vector3(
			position.x + DEGENERATE_DIRECTION.x * r,
			point.y,
			position.z + DEGENERATE_DIRECTION.y * r)
	var scale := r / distance
	return Vector3(position.x + dx * scale, point.y, position.z + dz * scale)


## XZ 平面上的圆心（Vector2 版本，调试绘制与测试用）
func center_xz() -> Vector2:
	return Vector2(position.x, position.z)


## 数据是否自洽（top_y > bottom_y 且半径非负）。坏数据在注册 / 构建阶段就该报出来。
func is_valid() -> bool:
	return top_y > bottom_y and radius_xz >= 0.0 and position.is_finite()


func describe() -> String:
	return "NavObstacle(center=(%.1f, %.1f) r=%.1f y=[%.1f, %.1f])" % [
		position.x, position.z, radius_xz, bottom_y, top_y]
