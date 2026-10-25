class_name ViewProjection
extends RefCounted

## 双视图的唯一差异点（ADR-0001 / ARCHITECTURE「五个核心接口」的第一个）。
##
## 上层（选择、命令、UI、射程圈、编队指示）**只调本类**，
## 禁止出现 `if is_2d` / `if mode == VIEW_2D` 之类的分支 —— 一出现，双视图纪律就废了。
##
## 差异全部收在「相机用的是透视还是正交」里，而不是收在调用方：
##   Camera3D 对两种投影都提供 project_ray_origin / project_ray_normal /
##   unproject_position，所以这里**只有一套数学**（射线 → 参考平面求交）。
##   写两套数学的代价是：三个月后 2D 那套和 3D 那套悄悄对不上，点选开始"差一点"。
##
## 参考平面（reference plane）：
##   screen_to_world 必须回答"这次点击落在哪个高度"。RTS 的直觉答案是
##   「当前焦点所在的高度层」（默认 L1 = y 0），由相机装配器在切换 / 平移后写入。
##   于是 world→screen→world 的往返是数值误差级别（见 scenes/dev/verify_camera.tscn）。
##   注意：高度不同的目标（L0 -400 / L2 +400 的单位）投影仍按**真实 3D 位置**算，
##   因此点选 / 框选与视觉始终一致（ADR-0001 里否掉 "-z*0.22 屏幕偏移" 就是这个理由）。
##
## 本类刻意不做：
##   - 拾取用物理射线（现在还没有碰撞体；先在屏幕空间筛距离，够用且可单测）
##   - 视口裁剪 / LOD / billboard（表现层的事）
##   - 相机移动（RtsCamera3D / RtsCamera2D 的事）

## 当前相机是哪种投影。**只为诊断与断言**存在，业务代码不应据此分支。
enum ProjectionMode { PERSPECTIVE, ORTHOGRAPHIC }

## 点选半径（屏幕像素）。指尖/鼠标抖一点也要能选中。
const DEFAULT_PICK_RADIUS_PX := 18.0
## 射线与参考平面近乎平行时的判据（|dir.y| 小于它就不做除法）
const RAY_PARALLEL_EPSILON := 1.0e-5
## screen_to_world 的 fallback_depth 不能是 0 或负数，否则点会落在相机背后
const MIN_FALLBACK_DEPTH := 1.0

var _camera: Camera3D = null
var _mode := ProjectionMode.PERSPECTIVE
var _reference_height := 0.0
var _pick_radius := DEFAULT_PICK_RADIUS_PX


## 绑定一台相机并嗅出它的投影方式。相机可以随时换（模式切换时由装配器重绑），
## 换完必须同步 set_reference_height()，否则 screen_to_world 还落在旧高度层。
func setup(camera: Camera3D) -> void:
	if camera == null:
		push_error("[ViewProjection] setup() 收到 null 相机，投影进入无效状态")
		_camera = null
		return
	_camera = camera
	_mode = (ProjectionMode.ORTHOGRAPHIC
		if camera.projection == Camera3D.PROJECTION_ORTHOGONAL
		else ProjectionMode.PERSPECTIVE)


## 是否已绑定一台在场景树里的相机。未就绪时所有换算返回零值，不抛错。
func is_ready() -> bool:
	return _camera != null and _camera.is_inside_tree()


## 当前相机（装配器 / 调试用）
func camera() -> Camera3D:
	return _camera


## 当前投影方式（仅诊断 / 断言用）
func mode() -> ProjectionMode:
	return _mode


func is_orthographic() -> bool:
	return _mode == ProjectionMode.ORTHOGRAPHIC


## 屏幕→世界所用的水平面高度。相机装配器在焦点变化后必须同步一次。
func set_reference_height(height: float) -> void:
	_reference_height = height


func reference_height() -> float:
	return _reference_height


## 点选半径，单位像素
func set_pick_radius(px: float) -> void:
	_pick_radius = maxf(0.0, px)


func pick_radius() -> float:
	return _pick_radius


## 视口尺寸（屏幕坐标系的边界）。派生出的换算全靠它，别在别处重复取。
func viewport_size() -> Vector2:
	if not is_ready():
		return Vector2.ZERO
	var vp := _camera.get_viewport()
	if vp == null:
		return Vector2.ZERO
	return vp.get_visible_rect().size


## 世界 → 屏幕（像素）。点在相机背后时返回值无意义，调用方先问 is_visible()。
func world_to_screen(world: Vector3) -> Vector2:
	if not is_ready():
		return Vector2.ZERO
	return _camera.unproject_position(world)


## 该世界点是否在相机前方（用于过滤"投影到屏幕对面"的假命中）。
func is_visible(world: Vector3) -> bool:
	if not is_ready():
		return false
	return not _camera.is_position_behind(world)


## 屏幕 → 世界：射线与参考平面（y = reference_height）求交。
## 射线与平面平行或交点在相机背后时，退化成「沿射线走 fallback_depth 米」——
## 这是给"抬头看天"这类病态输入留的确定行为，不是正常路径。
func screen_to_world(screen: Vector2, fallback_depth: float = 1000.0) -> Vector3:
	if not is_ready():
		return Vector3.ZERO
	var origin := _camera.project_ray_origin(screen)
	var dir := _camera.project_ray_normal(screen)
	if absf(dir.y) > RAY_PARALLEL_EPSILON:
		var t := (_reference_height - origin.y) / dir.y
		if t >= 0.0:
			return origin + dir * t
	return origin + dir * maxf(fallback_depth, MIN_FALLBACK_DEPTH)


## 参考平面上 1 像素 = 多少世界单位。拖拽平移 / 指示线宽都靠这个，
## 它把「透视 vs 正交」的差异也一起吸收掉了（透视下随缩放变化，正交下恒定）。
func world_units_per_pixel() -> float:
	var size := viewport_size()
	if size.y <= 0.0:
		return 0.0
	var center := size * 0.5
	var a := screen_to_world(center)
	var b := screen_to_world(center + Vector2(0.0, 1.0))
	return a.distance_to(b)


## 点选：在屏幕空间找离 screen 最近、且在 pick_radius 内的候选。
## candidates 的元素可以是 Vector3，也可以是带 global_position / position 的对象或字典。
## 返回原候选本身（不是坐标），没命中返回 null。
func pick_point(screen: Vector2, candidates: Array) -> Variant:
	if not is_ready():
		return null
	var best: Variant = null
	var best_distance := _pick_radius
	for candidate in candidates:
		var world: Variant = _candidate_position(candidate)
		if world == null:
			continue
		if not is_visible(world):
			continue
		var d := world_to_screen(world).distance_to(screen)
		if d <= best_distance:
			best_distance = d
			best = candidate
	return best


## 框选：候选全部转屏幕坐标后做矩形判定，2D / 3D 同一套代码。
func pick_rect(screen_rect: Rect2, candidates: Array) -> Array:
	var picked: Array = []
	if not is_ready():
		return picked
	for candidate in candidates:
		var world: Variant = _candidate_position(candidate)
		if world == null:
			continue
		if not is_visible(world):
			continue
		if screen_rect.has_point(world_to_screen(world)):
			picked.append(candidate)
	return picked


## 从候选里取世界坐标。刻意宽容（Vector3 / 对象 / 字典都吃），
## 因为单位数据对象（RefCounted）和表现节点（Node3D）会同时当候选传进来。
## 返回 Variant：Vector3 或 null（无法取坐标）。
func _candidate_position(candidate: Variant) -> Variant:
	if candidate is Vector3:
		return candidate
	if candidate is Dictionary:
		var dict := candidate as Dictionary
		for key in [&"global_position", &"position"]:
			if dict.has(key) and dict[key] is Vector3:
				return dict[key]
		return null
	if candidate is Object:
		var obj := candidate as Object
		for property in [&"global_position", &"position"]:
			var value: Variant = obj.get(property)
			if value is Vector3:
				return value
	return null
