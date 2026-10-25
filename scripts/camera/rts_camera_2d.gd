class_name RtsCamera2D
extends Node3D

## 2D 正交俯视相机（ADR-0001 的"保留原版指挥手感"那一半）。
##
## 用 Camera3D + PROJECTION_ORTHOGONAL，不是 Camera2D：模拟层永远只有一套 3D 数据
## （position: Vector3），2D 模式只是镜头换了，不换坐标系、不换场景。
##
## 与原 2D 版一致的地方（零学习成本）：
##   平移 = 右键拖拽；缩放 = 滚轮改正交视野
## 刻意不做（ADR-0002：2D 模式无旋转、无俯仰）：
##   没有 yaw / pitch / focus_height 旋钮。谁想加，先改 ADR。
##
## 「相机高度」是内部常量：正交投影下高度不影响成像，只影响裁剪范围。
## 放在 15000 m 是为了让 L0(-400) / L1(0) / L2(+400) 三层都在 near..far 之间。

## 正交视野（视口高度方向覆盖多少米）变化
signal size_changed(view_size: float)

## 正交视野下限：与 3D 的 MIN_DISTANCE（30 m）对齐
const MIN_SIZE := RtsCamera3D.MIN_DISTANCE
## 正交视野上限：与 3D 的 MAX_DISTANCE（12 km）对齐
const MAX_SIZE := RtsCamera3D.MAX_DISTANCE
## 相机放置高度（正交投影下不影响成像，只决定裁剪范围）
const CAMERA_HEIGHT := 15000.0
const CAMERA_NEAR := 1.0
const CAMERA_FAR := 40000.0
## 焦点可移动范围：与 3D 相机同一套钳位
const FOCUS_LIMIT_XZ := RtsCamera3D.FOCUS_LIMIT_XZ
const FOCUS_LIMIT_Y := RtsCamera3D.FOCUS_LIMIT_Y
const DEFAULT_SIZE := RtsCamera3D.DEFAULT_DISTANCE
## 滚轮一格的大小倍率（与 3D 缩放同倍率，切换模式时画面大小才不会跳）
const ZOOM_FACTOR := RtsCamera3D.ZOOM_FACTOR
## 拖拽超过这么多像素才算"拖"，否则留给上层当点击（右键点击 = 移动命令）
const DRAG_THRESHOLD_PX := RtsCamera3D.DRAG_THRESHOLD_PX

## 焦点（视图中心在世界 XZ 上的落点）。写入即瞬时生效。
var focus_position: Vector3:
	get:
		return _focus
	set(value):
		snap_focus(value)

## 正交视野大小（米）
var view_size: float:
	get:
		return _size
	set(value):
		zoom_to(value, true)

## 是否自己处理输入。T-1.3 InputRouter 接管后置 false。
var accept_input := true

var _focus := Vector3.ZERO
var _size := DEFAULT_SIZE
var _camera: Camera3D = null
## 内部自用的投影换算（拖拽时的"像素→米"），与装配器共用同一套数学
var _projection := ViewProjection.new()
var _drag_button := MOUSE_BUTTON_NONE
var _drag_travel := 0.0


func _ready() -> void:
	_camera = get_node_or_null(^"Camera3D") as Camera3D
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = _size
	_camera.near = CAMERA_NEAR
	_camera.far = CAMERA_FAR
	_projection.setup(_camera)
	_apply_transform()


func _process(delta: float) -> void:
	if accept_input:
		var axis := Input.get_vector(
			&"camera_pan_left", &"camera_pan_right", &"camera_pan_up", &"camera_pan_down")
		if axis != Vector2.ZERO:
			pan(axis * _size * RtsCamera3D.PAN_SPEED_RATIO * delta)


## 供 ViewProjection 绑定的相机
func camera() -> Camera3D:
	return _camera


## 在屏幕平面平移焦点（不改高度）。offset：(x = 屏幕右, y = 屏幕上)，单位米。
func pan(offset: Vector2) -> void:
	if offset == Vector2.ZERO:
		return
	# 2D 模式下屏幕上 = 世界 -Z（俯视时北朝上），所以 forward 取 -Z
	_focus += Vector3(offset.x, 0.0, -offset.y)
	_focus = _clamp_focus(_focus)
	_apply_transform()


## 瞬时把焦点放到位（模式切换 / 初始化）
func snap_focus(world_pos: Vector3) -> void:
	_focus = _clamp_focus(world_pos)
	_apply_transform()


## 与 3D 相机同名接口：2D 没有"平滑飞过去"的必要（正交下位移无透视变化），
## 但保留同样签名，装配器才能对两台相机一视同仁地调（instant 参数被忽略）。
func focus_on(world_pos: Vector3, _instant := false) -> void:
	snap_focus(world_pos)


## 滚轮：一格。正数拉近（视野变小）
func zoom_steps(steps: float) -> void:
	if is_zero_approx(steps):
		return
	zoom_to(_size / pow(ZOOM_FACTOR, steps), true)


func zoom_in() -> void:
	zoom_steps(1.0)


func zoom_out() -> void:
	zoom_steps(-1.0)


## 设定正交视野。范围对应 3D 的 30 m ~ 12 km（切换模式时画面不会突然放大/缩小）。
func zoom_to(value: float, instant := true) -> void:
	_size = clampf(value, MIN_SIZE, MAX_SIZE)
	if _camera != null:
		_camera.size = _size
	size_changed.emit(_size)
	if instant:
		_apply_transform()


func _clamp_focus(world_pos: Vector3) -> Vector3:
	return Vector3(
		clampf(world_pos.x, -FOCUS_LIMIT_XZ, FOCUS_LIMIT_XZ),
		clampf(world_pos.y, -FOCUS_LIMIT_Y, FOCUS_LIMIT_Y),
		clampf(world_pos.z, -FOCUS_LIMIT_XZ, FOCUS_LIMIT_XZ))


## 唯一写 transform 处。正交俯视：forward = -Y，屏幕上方 = 世界 -Z，
## 基矩阵手搓而不用 look_at —— 正下方看时 up 向量与视线平行，look_at 会退化。
func _apply_transform() -> void:
	if _camera == null:
		return
	var basis := Basis(Vector3(1.0, 0.0, 0.0), Vector3(0.0, 0.0, -1.0), Vector3(0.0, 1.0, 0.0))
	_camera.global_transform = Transform3D(basis, Vector3(_focus.x, CAMERA_HEIGHT, _focus.z))
	_projection.set_reference_height(_focus.y)


func _unhandled_input(event: InputEvent) -> void:
	if not accept_input:
		return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.pressed and button.is_action_pressed(&"camera_zoom_in", false, true):
			zoom_in()
			get_viewport().set_input_as_handled()
			return
		if button.pressed and button.is_action_pressed(&"camera_zoom_out", false, true):
			zoom_out()
			get_viewport().set_input_as_handled()
			return
		if button.button_index == MOUSE_BUTTON_MIDDLE or button.button_index == MOUSE_BUTTON_RIGHT:
			if button.pressed:
				_drag_button = button.button_index
				_drag_travel = 0.0
			elif button.button_index == _drag_button:
				_drag_button = MOUSE_BUTTON_NONE
		return

	if event is InputEventMouseMotion and _drag_button != MOUSE_BUTTON_NONE:
		var motion := event as InputEventMouseMotion
		_drag_travel += motion.relative.length()
		if _drag_travel < DRAG_THRESHOLD_PX:
			return
		pan(Vector2(-motion.relative.x, motion.relative.y) * _projection.world_units_per_pixel())
		get_viewport().set_input_as_handled()
