class_name RtsCamera3D
extends Node3D

## 3D 焦点轨道相机（ADR-0002：**禁止自由飞行**）。
##
## 一等公民只有一个：焦点 focus_position。相机永远是
##   position = focus - look_dir * distance
## 所有操作都是「移动焦点」或「围绕焦点转身」或「改距离」，
## 没有一处允许单独挪相机 —— 否则玩家会在 3D 里彻底迷失（ADR-0002 选项 1）。
##
## 手感对齐原 2D 版（零学习成本）：
##   平移 = 焦点在相机地平面滑动   ← 就是原版的"拖拽地图"
##   缩放 = 改相机到焦点的距离，**不改 FOV**（改 FOV 会透视变形，RTS 不可接受）
##   绕行 = Q/E 或 Alt+左键拖拽；俯仰 = Shift+滚轮
##
## 尺度全部来自 docs/scale-and-units.md「相机」段，写死在常量里，场景里不用手填：
##   FOV 55° / near 1.0 / far 40000 / 缩放距离 30 m ~ 12 km。
##
## 本类只管相机，不做拾取（ViewProjection 的事），不碰单位（模拟层的事）。
## 输入自己接了一份（`accept_input`），T-1.3 InputRouter 落地后可以把它关掉改由
## InputRouter 调本类的公开方法 —— 两条路都不需要改这里的数学。

## 相机到焦点的距离变化（缩放 / 聚焦时表现层要跟着调 LOD、圈大小）
signal distance_changed(distance: float)

# ---------------------------------------------------------------- 尺度常量

## 相机到焦点的最小距离（docs/scale-and-units.md：30 m）
const MIN_DISTANCE := 30.0
## 相机到焦点的最大距离（12 km）
const MAX_DISTANCE := 12000.0
## 俯仰下限（往下看 85°）
const MIN_PITCH_DEG := -85.0
## 俯仰上限（往下看 5°，再平就成 FPS 视角了）
const MAX_PITCH_DEG := -5.0
## 相机不得低于的高度（"不得穿地"护栏，ADR-0002 护栏 1）
const MIN_CAMERA_HEIGHT := 5.0
## 焦点可移动范围：战场 40 km 见方 + 20% 余量（docs/scale-and-units.md）
const FOCUS_LIMIT_XZ := 24000.0
## 焦点高度层之外的余量（L0 -400 / L1 0 / L2 +400）
const FOCUS_LIMIT_Y := 2000.0
const CAMERA_FOV_DEG := 55.0
const CAMERA_NEAR := 1.0
const CAMERA_FAR := 40000.0

# ---------------------------------------------------------------- 手感常量

const DEFAULT_DISTANCE := 1500.0
const DEFAULT_PITCH_DEG := -45.0
## 滚轮一格的距离倍率
const ZOOM_FACTOR := 1.15
## Q/E 绕行速度（度/秒）
const ORBIT_SPEED_DEG := 90.0
## Shift+滚轮 一格的俯仰变化（度）
const PITCH_STEP_DEG := 5.0
## WASD 平移速度 = 距离 × 该系数（每秒）。等于"一秒横穿一屏"。
const PAN_SPEED_RATIO := 1.0
## 聚焦飞行的指数收敛速度（越大越快）
const FOCUS_SMOOTH_SPEED := 8.0
## 缩放的指数收敛速度
const ZOOM_SMOOTH_SPEED := 12.0
## 拖拽超过这么多像素才算"拖"，否则留给上层当点击（右键点击 = 移动命令）
const DRAG_THRESHOLD_PX := 4.0

## 焦点。写入等于「设定目标并平滑飞过去」，即时移动请用 pan() / snap_focus()。
var focus_position: Vector3:
	get:
		return _focus
	set(value):
		_focus_target = _clamp_focus(value)
		_apply_transform()

## 相机到焦点的距离（读当前值；写入为即时跳变，滚轮走 zoom_steps() 的平滑）。
var distance: float:
	get:
		return _distance
	set(value):
		zoom_to(value, true)

## 水平朝向（度，绕世界 +Y）
var yaw_degrees: float:
	get:
		return _yaw_deg
	set(value):
		set_yaw_degrees(value)

## 俯仰（度）。负值 = 向下看，钳在 MIN_PITCH_DEG..MAX_PITCH_DEG。
var pitch_degrees: float:
	get:
		return _pitch_deg
	set(value):
		set_pitch_degrees(value)

## 是否自己处理输入。T-1.3 InputRouter 接管后置 false，改调本类公开方法。
var accept_input := true

var _focus := Vector3.ZERO
var _focus_target := Vector3.ZERO
var _distance := DEFAULT_DISTANCE
var _target_distance := DEFAULT_DISTANCE
var _yaw_deg := 0.0
var _pitch_deg := DEFAULT_PITCH_DEG
var _camera: Camera3D = null
## 内部自用的投影换算（拖拽时的"像素→米"）。和装配器共享同一套数学，不另写一份。
var _projection := ViewProjection.new()
var _drag_button := MOUSE_BUTTON_NONE
var _drag_travel := 0.0


func _ready() -> void:
	_camera = get_node_or_null(^"Camera3D") as Camera3D
	if _camera == null:
		# 允许纯代码装配（验证场景 / 单测）：没有子相机就自己造一台
		_camera = Camera3D.new()
		_camera.name = "Camera3D"
		add_child(_camera)
	# 尺度写死在这一处，场景文件里不用手填（改之前先开 ADR）
	_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	_camera.fov = CAMERA_FOV_DEG
	_camera.near = CAMERA_NEAR
	_camera.far = CAMERA_FAR
	_distance = DEFAULT_DISTANCE
	_target_distance = DEFAULT_DISTANCE
	_projection.setup(_camera)
	_apply_transform()


func _process(delta: float) -> void:
	_step_smoothing(delta)
	if accept_input:
		_step_key_input(delta)
	_apply_transform()


# ---------------------------------------------------------------- 输出

## 供 ViewProjection 绑定的相机
func camera() -> Camera3D:
	return _camera


## 聚焦目标的当前位置（平滑完成后与 focus_position 相等）
func focus_target() -> Vector3:
	return _focus_target


## 平滑中的目标距离（HUD 显示缩放档位 / 断言用）
func target_distance() -> float:
	return _target_distance


# ---------------------------------------------------------------- 平移

## 在相机地平面平移焦点。offset 单位米：(x = 屏幕右, y = 屏幕上)。
## WASD、拖拽、聚焦跟随全部走这一个入口 —— 三个入口三套数学是 bug 温床。
func pan(offset: Vector2) -> void:
	if offset == Vector2.ZERO:
		return
	var yaw_basis := Basis(Vector3.UP, deg_to_rad(_yaw_deg))
	var right := yaw_basis * Vector3.RIGHT
	var forward := yaw_basis * Vector3.FORWARD
	# 平移要"跟手"：直接改当前值与目标值，不走 focus_on 的平滑
	_focus_target = _clamp_focus(_focus_target + right * offset.x + forward * offset.y)
	_focus = _focus_target
	_apply_transform()


## 瞬时把焦点放到位（模式切换 / 初始化 / 读档）
func snap_focus(world_pos: Vector3) -> void:
	_focus_target = _clamp_focus(world_pos)
	_focus = _focus_target
	_apply_transform()


## 平滑聚焦（空格聚焦所选 / 双击单位）。instant 表示不要插值。
func focus_on(world_pos: Vector3, instant := false) -> void:
	_focus_target = _clamp_focus(world_pos)
	if instant:
		_focus = _focus_target
		_apply_transform()


# ---------------------------------------------------------------- 缩放

## 滚轮：一格。正数拉近，负数拉远。
func zoom_steps(steps: float) -> void:
	if is_zero_approx(steps):
		return
	_target_distance = clampf(_target_distance / pow(ZOOM_FACTOR, steps), MIN_DISTANCE, MAX_DISTANCE)


func zoom_in() -> void:
	zoom_steps(1.0)


func zoom_out() -> void:
	zoom_steps(-1.0)


## 设定距离。instant=false 走平滑；instant=true 立刻到位（测试 / 模式切换）。
## 无论哪条路都过同一次钳位：距离下限 30 m 是护栏，不是建议。
func zoom_to(value: float, instant := false) -> void:
	_target_distance = clampf(value, MIN_DISTANCE, MAX_DISTANCE)
	if instant:
		_distance = _target_distance
		distance_changed.emit(_distance)
	_apply_transform()


# ---------------------------------------------------------------- 旋转

## 水平绕行（度）
func orbit(degrees: float) -> void:
	set_yaw_degrees(_yaw_deg + degrees)


func set_yaw_degrees(value: float) -> void:
	_yaw_deg = wrapf(value, -180.0, 180.0)
	_apply_transform()


## 俯仰（度）。钳在 -85..-5，超出即边界值（护栏，不是建议）。
func set_pitch_degrees(value: float) -> void:
	_pitch_deg = clampf(value, MIN_PITCH_DEG, MAX_PITCH_DEG)
	_apply_transform()


func pitch_by(degrees: float) -> void:
	set_pitch_degrees(_pitch_deg + degrees)


# ---------------------------------------------------------------- 护栏

## 焦点钳位：战场范围 + 20% 余量，高度层之外留一点余量。
func _clamp_focus(world_pos: Vector3) -> Vector3:
	return Vector3(
		clampf(world_pos.x, -FOCUS_LIMIT_XZ, FOCUS_LIMIT_XZ),
		clampf(world_pos.y, -FOCUS_LIMIT_Y, FOCUS_LIMIT_Y),
		clampf(world_pos.z, -FOCUS_LIMIT_XZ, FOCUS_LIMIT_XZ))


## 轨道基：先绕 Y 转 yaw，再绕 X 转 pitch。相机的 -Z 就是看向焦点的方向。
func _orbit_basis() -> Basis:
	var yaw := Basis(Vector3.UP, deg_to_rad(_yaw_deg))
	var pitch := Basis(Vector3.RIGHT, deg_to_rad(_pitch_deg))
	return yaw * pitch


## 把 _focus / _distance / _yaw / _pitch 落到相机变换上。唯一的写 transform 处。
func _apply_transform() -> void:
	if _camera == null:
		return
	var dir := _orbit_basis() * Vector3.FORWARD
	var pos := _focus - dir * _distance
	if pos.y < MIN_CAMERA_HEIGHT:
		# 护栏：不得穿地。抬高后仍 look_at 焦点，视角只是变缓，不会丢目标。
		pos.y = MIN_CAMERA_HEIGHT
	_camera.global_position = pos
	_camera.look_at(_focus, Vector3.UP)
	_projection.set_reference_height(_focus.y)


# ---------------------------------------------------------------- 每帧

func _step_smoothing(delta: float) -> void:
	if _focus != _focus_target:
		var t := 1.0 - exp(-FOCUS_SMOOTH_SPEED * delta)
		_focus = _focus.lerp(_focus_target, t)
		if _focus.distance_to(_focus_target) < 0.05:
			_focus = _focus_target
	if not is_equal_approx(_distance, _target_distance):
		var t := 1.0 - exp(-ZOOM_SMOOTH_SPEED * delta)
		_distance = lerpf(_distance, _target_distance, t)
		if absf(_distance - _target_distance) < 0.05:
			_distance = _target_distance
		distance_changed.emit(_distance)


## WASD / QE 的持续输入。轮询而非事件：按住是常态，事件流反而更麻烦。
func _step_key_input(delta: float) -> void:
	var axis := Input.get_vector(
		&"camera_pan_left", &"camera_pan_right", &"camera_pan_up", &"camera_pan_down")
	if axis != Vector2.ZERO:
		# 速度随距离走：拉远时一次能扫过大片战场，拉近时精细
		pan(axis * _distance * PAN_SPEED_RATIO * delta)
	if Input.is_action_pressed(&"camera_orbit_left"):
		orbit(-ORBIT_SPEED_DEG * delta)
	if Input.is_action_pressed(&"camera_orbit_right"):
		orbit(ORBIT_SPEED_DEG * delta)


# ---------------------------------------------------------------- 输入

## 离散输入（滚轮 / 拖拽）。持续按键在 _step_key_input 里轮询。
## 拖拽超过 DRAG_THRESHOLD_PX 才算平移，并且这时才吃掉事件 ——
## 不足阈值的右键仍会向上冒泡，留给 T-1.3 当"移动命令"，两种操作因此不打架。
func _unhandled_input(event: InputEvent) -> void:
	if not accept_input:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
		return

	if event is InputEventMouseMotion and _drag_button != MOUSE_BUTTON_NONE:
		var motion := event as InputEventMouseMotion
		_drag_travel += motion.relative.length()
		if _drag_travel < DRAG_THRESHOLD_PX:
			return
		# 抓住地图拖动：内容跟着光标走，所以焦点反向走
		pan(Vector2(-motion.relative.x, motion.relative.y) * _projection.world_units_per_pixel())
		get_viewport().set_input_as_handled()


func _handle_mouse_button(button: InputEventMouseButton) -> void:
	if button.pressed and button.is_action_pressed(&"camera_zoom_in", false, true):
		zoom_in()
		get_viewport().set_input_as_handled()
		return
	if button.pressed and button.is_action_pressed(&"camera_zoom_out", false, true):
		zoom_out()
		get_viewport().set_input_as_handled()
		return
	if button.pressed and button.is_action_pressed(&"camera_pitch_up", false, true):
		pitch_by(PITCH_STEP_DEG)
		get_viewport().set_input_as_handled()
		return
	if button.pressed and button.is_action_pressed(&"camera_pitch_down", false, true):
		pitch_by(-PITCH_STEP_DEG)
		get_viewport().set_input_as_handled()
		return

	if button.button_index == MOUSE_BUTTON_MIDDLE or button.button_index == MOUSE_BUTTON_RIGHT:
		if button.pressed:
			_drag_button = button.button_index
			_drag_travel = 0.0
		elif button.button_index == _drag_button:
			_drag_button = MOUSE_BUTTON_NONE
