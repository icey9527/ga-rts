class_name InputRouter
extends Node

## 交互层总入口（ARCHITECTURE L3，scripts/input/）。
##
## 一句话职责：InputMap action → 相机 / 选择 / CommandBus。
## 本文件**不写任何单位状态**（硬规则 1）。它只有三种出口：
##   1. 相机 —— 调 RtsCameraRig / 当前相机节点的公开方法（本类不碰 transform）
##   2. 选择 —— 写自己的选中列表，并镜像到 GameState.set_selected_units（唯一落点）
##   3. 命令 —— 只经过 CommandBus.issue()
##
## 双视图纪律（ADR-0001）：拾取一律走 ViewProjection（pick_point / pick_rect /
## screen_to_world），因此本类不知道当前是 2D 还是 3D。全文件唯一出现模式判断的地方是
## `_active_camera()` —— 那是"把相机操作发给哪台相机"的硬件路由，不是业务分支
## （业务分支会直接导致 ADR-0001 失效，不要加第二个）。
##
## 事件流：一律走 _unhandled_input，**不轮询 Input**。持续型（WASD / QE）由按键事件
## 维护一张"按住中"的表，在 _process 里按 delta 步进 —— 仍然是事件驱动，只是把
## "按住了多久"这件事换算成位移。
##
## 右键冲突（本卡最关键的一条）：
##   右键既是相机平移拖拽，又是移动命令。判定只看位移阈值，不看时长：
##     按下           → 只记位置，什么都不做
##     位移 > 4 px    → 进入拖拽，交给相机平移；松手**不发命令**
##     位移 ≤ 4 px    → 当作点击，screen_to_world 拾取目标点，发 cmd_move
##   左键走同一套状态机：拖拽 → pick_rect 框选；点击 → pick_point 点选。
##
## A / S 的双重身份：project.godot 里它们既是 camera_pan_left / camera_pan_down，
## 又是 cmd_attack_move / cmd_stop（docs/controls.md 两张表各自都成立，Godot 的
## InputMap 不做互斥）。本类的裁决见 AMBIGUOUS_HOLD_MS 注释。

## 选中列表变化（HUD / 选择框表现层接这里）
signal selection_changed(units: Array)
## 框选中：active=true 表示正在拖框（每帧随位移更新），false 表示本次框选结束
signal box_select_changed(screen_rect: Rect2, active: bool)
## 待落点的命令模式变化（A 进入攻击移动 / Shift+A 进入改高度层）
signal command_mode_changed(mode: int)
## R 键（射程显示）。表现层自己去响应，本类只记住"该不该显示"
signal range_display_changed(enabled: bool)
## 按住 Alt 时的高度层高亮
signal altitude_highlight_changed(enabled: bool)
## PageUp / PageDown 切换焦点高度层（索引对应 ALTITUDE_LAYERS）
signal altitude_layer_changed(layer_index: int)
## 暂停开关被按下（Space）。**本类不直接改 Simulation**：
## 输入层只负责“玩家想暂停”这件事，真正改模拟状态由接线层（battle.gd）做。
signal pause_toggled

## 点击 / 拖拽的判定阈值（像素）。与相机自带的同名常量口径一致：
## 小于它就是一次点击，大于它才是一次拖拽。
const DRAG_THRESHOLD_PX := 4.0
## A / S 的歧义裁决阈值（毫秒）：
##   短按 → 命令（A 进入攻击移动模式 / S 停止）—— 键位语义以 docs/controls.md 的
##          "命令" 表为准，那是玩家手指记忆的落脚点
##   长按 → 平移（A 左移 / S 下移），且松手不发命令
## 为什么要一分为二：project.godot 让同一个物理键同时属于两个 action，不裁决就会
## "按住 A 平移的同时把全队切成攻击移动状态"。正确的长期修法是改 InputMap
## （平移换 W/↑↓←→ 或把攻击移动改成 A+左键的纯修饰键），那是另一张卡的事。
const AMBIGUOUS_HOLD_MS := 260
## 键盘平移速度 = 屏幕高度 × 该系数（每秒）。等价于"一秒横穿一屏"。
const PAN_SPEED_RATIO := 1.0
## Q/E 绕行速度（度/秒）
const ORBIT_SPEED_DEG := 90.0
## 滚轮俯仰步长（度）
const PITCH_STEP_DEG := 5.0
## 滚轮一格（正数拉近）
const ZOOM_STEP := 1.0
## 高度层（docs/adr/0003-layered-altitude.md：L0 -400 / L1 0 / L2 +400）
const ALTITUDE_LAYERS: Array[float] = [-400.0, 0.0, 400.0]
## 默认高度层索引（L1）
const DEFAULT_ALTITUDE_LAYER := 1

# ---------------------------------------------------------------- 命令约定
#
# 命令 kind 直接沿用 InputMap 的 action 名，避免"输入名"和"命令名"各一套对不上。
# options 的固定键：point（世界坐标，Vector3）/ screen（像素，Vector2）/ source。

const CMD_MOVE := &"cmd_move"
const CMD_ATTACK := &"cmd_attack"
const CMD_ATTACK_MOVE := &"cmd_attack_move"
const CMD_STOP := &"cmd_stop"
const CMD_CHANGE_ALTITUDE := &"cmd_change_altitude"
## 命令来源标记。仲裁（S2）要按来源区分玩家 / AI / 任务脚本，本层是 player。
const COMMAND_SOURCE := &"input"

## 待落点的命令模式：先按键进入模式，下一次左键点击才真正发命令
## （docs/controls.md：攻击移动 = A + 左键，改高度层 = A + Shift + 左键）
enum CommandMode { NONE, ATTACK_MOVE, CHANGE_ALTITUDE }

## 持续型 action（按住生效）。事件维护 pressed/released，_process 按 delta 步进。
const HELD_ACTIONS: Array[StringName] = [
	&"camera_pan_up",
	&"camera_pan_down",
	&"camera_pan_left",
	&"camera_pan_right",
	&"camera_orbit_left",
	&"camera_orbit_right",
]

## 一个鼠标按键的拖拽状态机。三个键（左/右/中）各持一份，避免三套 if 嵌套。
class Pointer:
	extends RefCounted

	var button := MOUSE_BUTTON_NONE
	var pressed := false
	## 按下时的屏幕位置（拖拽 / 框选的锚点）
	var origin := Vector2.ZERO
	## 当前屏幕位置
	var current := Vector2.ZERO
	## 累计位移（像素）。判定点击 / 拖拽只看这个，不看到点时间
	var travel := 0.0
	## 已越过阈值 → 本次按下算拖拽
	var dragging := false

	func begin(index: MouseButton, pos: Vector2) -> void:
		button = index
		pressed = true
		origin = pos
		current = pos
		travel = 0.0
		dragging = false

	## 返回 true 表示本次 motion 把状态从"按下"推进到了"拖拽"
	func track(pos: Vector2, relative: Vector2, threshold: float) -> bool:
		current = pos
		travel += relative.length()
		if dragging:
			return false
		dragging = travel > threshold
		return dragging

	func end() -> void:
		pressed = false
		dragging = false

	func rect() -> Rect2:
		return Rect2(origin, current - origin).abs()


## 相机装配器（依赖注入，不写死节点路径）
var _rig: RtsCameraRig = null
## 双视图唯一投影（同样由外部注入）
var _projection: ViewProjection = null
## 选中列表（只读约定；写入走 set_selection）
var _selection: Array = []
## 可拾取候选（Vector3 / 带 position 的对象 / 字典，透传给 ViewProjection）
var _candidates: Array = []

var _command_mode := CommandMode.NONE
var _range_display := false
var _altitude_highlight := false
var _altitude_layer := DEFAULT_ALTITUDE_LAYER

## 按住中的 action → 按下时刻（毫秒）。用时间戳而不是 bool，是为了 A/S 的短按/长按判定。
var _held: Dictionary = {}

var _left := Pointer.new()
var _right := Pointer.new()
var _middle := Pointer.new()


# ---------------------------------------------------------------- 装配 / 读写口

## 依赖注入。rig 与 projection 都由场景装配器（Battle / 验证场景）给，不写死路径。
## 同时完成**相机输入接管**：两台相机自己那份输入必须关掉，否则同一个事件会被处理两次
## （相机平移一次、路由再平移一次，手感会变成两倍速）。
func setup(rig: RtsCameraRig, projection: ViewProjection) -> void:
	_rig = rig
	_projection = projection
	if _projection == null and _rig != null:
		_projection = _rig.view_projection()
	if _rig != null:
		_rig.accept_input = false
	set_process(true)


## 是否已注入依赖（未就绪时一律不处理输入，安静地什么都不做）
func is_ready() -> bool:
	return _rig != null and _projection != null


## 替换选中列表。写入同时镜像到 GameState（ARCHITECTURE：选择逻辑在这里，落点在 GameState）。
func set_selection(units: Array) -> void:
	_selection = units.duplicate()
	GameState.set_selected_units(_selection)
	selection_changed.emit(_selection)


## 当前选中列表（只读约定，别在原地改）
func selection() -> Array:
	return _selection


## 可拾取候选。卡里还没有 Unit 数据对象，先由调用方（验证场景 / 将来的 Battle）灌进来。
func set_candidates(candidates: Array) -> void:
	_candidates = candidates


func candidates() -> Array:
	return _candidates


## 当前待落点的命令模式
func command_mode() -> CommandMode:
	return _command_mode


## 当前焦点高度层索引（0 = L0 -400 m，1 = L1 0 m，2 = L2 +400 m）
func altitude_layer() -> int:
	return _altitude_layer


func range_display_enabled() -> bool:
	return _range_display


func altitude_highlight_enabled() -> bool:
	return _altitude_highlight


## 复位到干净状态（验证场景 / 场景切换用，不碰相机）
func reset() -> void:
	_held.clear()
	_left = Pointer.new()
	_right = Pointer.new()
	_middle = Pointer.new()
	_command_mode = CommandMode.NONE
	_altitude_layer = DEFAULT_ALTITUDE_LAYER
	_range_display = false
	_altitude_highlight = false
	_candidates = []
	set_selection([])


# ---------------------------------------------------------------- 输入入口

func _unhandled_input(event: InputEvent) -> void:
	if not is_ready():
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event as InputEventMouseButton)
		return
	if event is InputEventMouseMotion:
		_handle_mouse_motion(event as InputEventMouseMotion)
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if key.echo:
			return
		if key.pressed:
			_handle_key_pressed(key)
		else:
			_handle_key_released(key)


func _process(delta: float) -> void:
	if not is_ready():
		return
	_step_keyboard_camera(delta)


# ---------------------------------------------------------------- 每帧（持续型输入）

## WASD / QE 的持续输入。按住状态来自事件（_held），这里只把它换算成位移。
func _step_keyboard_camera(delta: float) -> void:
	var axis := _pan_axis()
	if axis != Vector2.ZERO:
		var size := _projection.viewport_size()
		if size.y > 0.0:
			# 一秒横穿一屏：像素位移 × 视口高度 × 系数
			var pixels := axis * size.y * PAN_SPEED_RATIO * delta
			_move_focus(_screen_pixels_to_focus(pixels))

	var orbit := 0.0
	if _held.has(&"camera_orbit_left"):
		orbit -= ORBIT_SPEED_DEG * delta
	if _held.has(&"camera_orbit_right"):
		orbit += ORBIT_SPEED_DEG * delta
	if not is_zero_approx(orbit):
		_orbit(orbit)


## 平移轴。(x = 屏幕右, y = 屏幕下)。A / S 只有按住超过阈值才参与平移。
func _pan_axis() -> Vector2:
	var axis := Vector2.ZERO
	if _held.has(&"camera_pan_right"):
		axis.x += 1.0
	if _hold_elapsed_ms(&"camera_pan_left") >= AMBIGUOUS_HOLD_MS:
		axis.x -= 1.0
	if _hold_elapsed_ms(&"camera_pan_down") >= AMBIGUOUS_HOLD_MS:
		axis.y += 1.0
	if _held.has(&"camera_pan_up"):
		axis.y -= 1.0
	return axis


## 该 action 已按住的时长（毫秒）。没按住返回 -1。
func _hold_elapsed_ms(action: StringName) -> int:
	if not _held.has(action):
		return -1
	return Time.get_ticks_msec() - int(_held[action])


# ---------------------------------------------------------------- 键盘

func _handle_key_pressed(key: InputEventKey) -> void:
	# 持续型：只记录按下时刻，位移在 _process 里换算
	for action in HELD_ACTIONS:
		if key.is_action_pressed(action, false, true):
			_held[action] = Time.get_ticks_msec()

	# Alt 本身就是一个 action（高度层高亮，按住生效）。这里**不能**用 exact_match：
	# 按下 Alt 时事件里的 alt_pressed 已经是 true，精确匹配会永远失败。
	if key.is_action_pressed(&"toggle_altitude_highlight", false, false):
		_set_altitude_highlight(true)
		return

	# 离散型：一个 action 一次动作
	if key.is_action_pressed(&"toggle_pause", false, true):
		pause_toggled.emit()
		get_viewport().set_input_as_handled()
		return
	if key.is_action_pressed(&"toggle_view_mode", false, true):
		_rig.toggle_mode()
		return
	if key.is_action_pressed(&"focus_selected", false, true):
		_focus_selection()
		return
	if key.is_action_pressed(&"altitude_layer_up", false, true):
		_change_altitude_layer(1)
		return
	if key.is_action_pressed(&"altitude_layer_down", false, true):
		_change_altitude_layer(-1)
		return
	if key.is_action_pressed(&"toggle_range_display", false, true):
		_set_range_display(not _range_display)
		return
	# Shift+A：改高度层（下一个左键点了算）。exact_match 保证普通 A 不会命中这里。
	if key.is_action_pressed(&"cmd_change_altitude", false, true):
		_set_command_mode(CommandMode.CHANGE_ALTITUDE)
		return


func _handle_key_released(key: InputEventKey) -> void:
	# A / S 的歧义裁决：短按 → 命令；长按 → 已经当平移用过了，松手什么都不发
	if key.is_action_released(&"camera_pan_left", true):
		_release_ambiguous(&"camera_pan_left", _arm_attack_move)
	if key.is_action_released(&"camera_pan_down", true):
		_release_ambiguous(&"camera_pan_down", _issue_stop)
	if key.is_action_released(&"toggle_altitude_highlight", false):
		_set_altitude_highlight(false)

	for action in HELD_ACTIONS:
		if key.is_action_released(action, true):
			_held.erase(action)


## 松手结算：按住时长不足阈值 → 当点击，执行命令语义；否则什么都不做（已经在平移了）。
func _release_ambiguous(action: StringName, on_tap: Callable) -> void:
	var pressed_at := _hold_elapsed_ms(action)
	_held.erase(action)
	if pressed_at < 0 or pressed_at >= AMBIGUOUS_HOLD_MS:
		return
	on_tap.call()


func _arm_attack_move() -> void:
	_set_command_mode(CommandMode.ATTACK_MOVE)


func _set_command_mode(mode: CommandMode) -> void:
	if _command_mode == mode:
		return
	_command_mode = mode
	command_mode_changed.emit(_command_mode)


func _set_range_display(enabled: bool) -> void:
	if _range_display == enabled:
		return
	_range_display = enabled
	range_display_changed.emit(_range_display)


func _set_altitude_highlight(enabled: bool) -> void:
	if _altitude_highlight == enabled:
		return
	_altitude_highlight = enabled
	altitude_highlight_changed.emit(_altitude_highlight)


# ---------------------------------------------------------------- 鼠标

func _handle_mouse_button(button: InputEventMouseButton) -> void:
	if not button.pressed:
		_release_pointer(button)
		return

	# 滚轮：裸滚轮 = 缩放，Shift+滚轮 = 俯仰（docs/controls.md 相机表）
	if button.is_action_pressed(&"camera_zoom_in", false, true):
		_zoom(ZOOM_STEP)
		get_viewport().set_input_as_handled()
		return
	if button.is_action_pressed(&"camera_zoom_out", false, true):
		_zoom(-ZOOM_STEP)
		get_viewport().set_input_as_handled()
		return
	if button.is_action_pressed(&"camera_pitch_up", false, true):
		_pitch(PITCH_STEP_DEG)
		get_viewport().set_input_as_handled()
		return
	if button.is_action_pressed(&"camera_pitch_down", false, true):
		_pitch(-PITCH_STEP_DEG)
		get_viewport().set_input_as_handled()
		return

	# 三个按键只是"按下记录位置"，真正的判定在 motion / release 里（阈值状态机）
	match button.button_index:
		MOUSE_BUTTON_LEFT:
			_left.begin(MOUSE_BUTTON_LEFT, button.position)
		MOUSE_BUTTON_RIGHT:
			_right.begin(MOUSE_BUTTON_RIGHT, button.position)
		MOUSE_BUTTON_MIDDLE:
			_middle.begin(MOUSE_BUTTON_MIDDLE, button.position)


func _release_pointer(button: InputEventMouseButton) -> void:
	var pos := button.position
	match button.button_index:
		MOUSE_BUTTON_LEFT:
			if not _left.pressed:
				return
			var was_dragging := _left.dragging
			var rect := _left.rect()
			_left.end()
			if was_dragging:
				# 拖拽超阈值 → 框选。**不**走点选，哪怕松手位置正好压着某个单位
				_apply_box_selection(rect, button.shift_pressed)
				box_select_changed.emit(rect, false)
				get_viewport().set_input_as_handled()
				return
			_handle_left_click(pos, button.shift_pressed, button.ctrl_pressed)
			return
		MOUSE_BUTTON_RIGHT:
			if not _right.pressed:
				return
			var panned := _right.dragging
			_right.end()
			if panned:
				# 拖拽超阈值 → 这次右键归属相机平移，松手**不发命令**
				return
			_handle_right_click(pos)
			get_viewport().set_input_as_handled()
			return
		MOUSE_BUTTON_MIDDLE:
			if not _middle.pressed:
				return
			_middle.end()


func _handle_mouse_motion(motion: InputEventMouseMotion) -> void:
	if _left.pressed:
		_left.track(motion.position, motion.relative, DRAG_THRESHOLD_PX)
		if _left.dragging:
			# 表现层的选择框跟着位移走（每个 motion 一次，不攒到松手）
			box_select_changed.emit(_left.rect(), true)
			get_viewport().set_input_as_handled()

	if _right.pressed:
		_right.track(motion.position, motion.relative, DRAG_THRESHOLD_PX)
		if _right.dragging:
			# 抓住地图拖动：内容跟着光标走，所以焦点反向走
			_move_focus(-_screen_pixels_to_focus(motion.relative))
			get_viewport().set_input_as_handled()

	if _middle.pressed:
		_middle.track(motion.position, motion.relative, DRAG_THRESHOLD_PX)
		if _middle.dragging:
			# 中键：横向拖拽 = 平移，纵向拖拽 = 俯仰（controls.md 相机表）
			_move_focus(-_screen_pixels_to_focus(Vector2(motion.relative.x, 0.0)))
			_pitch(-motion.relative.y * 0.2)
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- 左键：选择 / 待落点命令

func _handle_left_click(screen_pos: Vector2, additive: bool, same_type: bool) -> void:
	# 先看待落点的命令模式：A / Shift+A 按下之后的那一下左键是命令，不是选择
	if _command_mode != CommandMode.NONE:
		var kind := CMD_ATTACK_MOVE
		if _command_mode == CommandMode.CHANGE_ALTITUDE:
			kind = CMD_CHANGE_ALTITUDE
		_issue(kind, _point_options(screen_pos))
		_set_command_mode(CommandMode.NONE)
		return

	var hit: Variant = _projection.pick_point(screen_pos, _candidates)
	if hit == null:
		# 点空地：非加选就清空；加选保持原样（docs/controls.md：双击空地才是全选同屏）
		if not additive:
			set_selection([])
		return

	if same_type:
		set_selection(_same_type_of(hit))
		return

	if additive:
		# 加选 / 减选
		var merged := _selection.duplicate()
		var index := merged.find(hit)
		if index >= 0:
			merged.remove_at(index)
		else:
			merged.append(hit)
		set_selection(merged)
		return

	set_selection([hit])


func _apply_box_selection(screen_rect: Rect2, additive: bool) -> void:
	var picked := _projection.pick_rect(screen_rect, _candidates)
	if not additive:
		set_selection(picked)
		return
	var merged := _selection.duplicate()
	for unit in picked:
		if not merged.has(unit):
			merged.append(unit)
	set_selection(merged)


## 选中同类：按候选身上的 `type_id` / `type` 属性分组（Unit 数据对象落地后自动生效）。
## 候选是裸 Vector3 时没有类型可读，退化成"只选它自己"。
func _same_type_of(reference: Variant) -> Array:
	var key: Variant = _type_key(reference)
	if key == null:
		return [reference]
	var picked: Array = []
	for candidate in _candidates:
		if _type_key(candidate) == key:
			picked.append(candidate)
	return picked


func _type_key(candidate: Variant) -> Variant:
	if not (candidate is Object):
		return null
	var obj := candidate as Object
	for property in [&"type_id", &"type"]:
		if obj.get(property) != null:
			return obj.get(property)
	return null


# ---------------------------------------------------------------- 右键：命令

func _handle_right_click(screen_pos: Vector2) -> void:
	if _selection.is_empty():
		# 没选中任何东西就没有命令目标。CommandBus.issue(null) 会 push_error，这里先拦住。
		return
	var hit: Variant = _projection.pick_point(screen_pos, _candidates)
	if hit != null and _is_hostile(hit):
		var attack_options := _point_options(screen_pos)
		attack_options["target"] = hit
		_issue(CMD_ATTACK, attack_options)
		return
	_issue(CMD_MOVE, _point_options(screen_pos))


## 右键点了敌方单位 → 攻击（docs/controls.md 命令表）。
##
## **不能问候选自己**：Unit 上没有 is_hostile() 方法（"对谁而言是敌人"根本没法自答）。
## 原来那句 has_method 检查永远为假，于是右键点敌人也只发移动命令 ——
## 表现就是“能选中、能下令、就是永远打不起来”。
## 正确口径：敌我关系只能由「选中单位 vs 候选单位」这一对决定，读双方的 team 字段，
## 本层仍然不硬编码任何队伍号（队伍数据依旧归 L1/L0）。
func _is_hostile(candidate: Variant) -> bool:
	if _selection.is_empty():
		return false
	var my_team := _team_of(_selection[0])
	var other_team := _team_of(candidate)
	if my_team < 0 or other_team < 0:
		return false
	return my_team != other_team


## 取对象的队伍号。没有 team 字段的候选（地形 / 装饰 / 落点）返回 -1。
func _team_of(obj: Variant) -> int:
	if not (obj is Object):
		return -1
	var value: Variant = (obj as Object).get(&"team")
	if value == null:
		return -1
	var t := typeof(value)
	if t != TYPE_INT and t != TYPE_FLOAT:
		return -1
	return int(value)


# ---------------------------------------------------------------- 命令出口

func _issue_stop() -> void:
	_issue(CMD_STOP, {"source": COMMAND_SOURCE})


## 唯一的命令出口。目标恒为当前选中列表（CommandBus.issue 接受单个 / 列表 / 编队）。
func _issue(kind: StringName, options: Dictionary) -> bool:
	if _selection.is_empty():
		return false
	return CommandBus.issue(_selection, kind, options)


## 带世界落点的命令 options（移动 / 攻击 / 攻击移动 / 改高度层共用一套键）：
##   point  世界坐标（命令真正的落点，模拟层只认这个）
##   screen 触发时的屏幕坐标（表现层画反馈线用）
##   layer  当前焦点高度层索引（改高度层的目标层）
##   source 命令来源（仲裁用，本层恒为 input）
func _point_options(screen_pos: Vector2) -> Dictionary:
	return {
		"point": _projection.screen_to_world(screen_pos),
		"screen": screen_pos,
		"layer": _altitude_layer,
		"source": COMMAND_SOURCE,
	}


# ---------------------------------------------------------------- 相机出口

## 把相机操作发给"当前这台"相机。**全文件唯一的模式判断**，且只用于相机硬件路由：
## 选择 / 命令 / UI 一律走 ViewProjection，不得复制这套判断（ADR-0001）。
func _active_camera() -> Node3D:
	if _rig == null:
		return null
	if _rig.mode() == RtsCameraRig.ViewMode.VIEW_2D:
		return _rig.camera_2d
	return _rig.camera_3d


## 平移焦点。统一走局部位移，2D/3D 都是"焦点 + 位移"，不各写一套。
func _move_focus(world_delta: Vector3) -> void:
	if _rig == null or world_delta == Vector3.ZERO:
		return
	# instant=true：拖拽 / 按键平移必须跟手，不能走聚焦那条平滑插值
	_rig.focus_on(_rig.focus_position() + world_delta, true)
	_sync_reference_height()


## 屏幕像素位移 → 焦点在地平面上的位移。（x = 屏幕右, y = 屏幕下）
## 用屏幕空间的两根基向量换算，透视下的纵向缩放（前缩）与 2D/3D 差异都自动吸收。
func _screen_pixels_to_focus(pixels: Vector2) -> Vector3:
	if _projection == null or not _projection.is_ready():
		return Vector3.ZERO
	var center := _projection.viewport_size() * 0.5
	var origin := _projection.screen_to_world(center)
	var right := _projection.screen_to_world(center + Vector2(1.0, 0.0)) - origin
	var down := _projection.screen_to_world(center + Vector2(0.0, 1.0)) - origin
	return right * pixels.x + down * pixels.y


func _zoom(steps: float) -> void:
	var camera := _active_camera()
	if camera != null and camera.has_method(&"zoom_steps"):
		camera.call(&"zoom_steps", steps)


## 水平绕行。2D 相机没有这个能力（ADR-0002：2D 无旋转），has_method 直接跳过 ——
## 于是这里也不需要 if is_2d。
func _orbit(degrees: float) -> void:
	var camera := _active_camera()
	if camera != null and camera.has_method(&"orbit"):
		camera.call(&"orbit", degrees)


## 俯仰。2D 相机同样没有（has_method 跳过）。
func _pitch(degrees: float) -> void:
	var camera := _active_camera()
	if camera != null and camera.has_method(&"pitch_by"):
		camera.call(&"pitch_by", degrees)


## 相机装配器在焦点变化后必须同步一次投影的参考平面（点选落在哪个高度层）。
## 装配器只在模式切换时同步，平移 / 换层 / 聚焦由本层补上。
func _sync_reference_height() -> void:
	if _rig != null and _projection != null:
		_projection.set_reference_height(_rig.focus_position().y)


# ---------------------------------------------------------------- 聚焦 / 高度层

## 空格：焦点平滑飞到选中单位的中心
func _focus_selection() -> void:
	var center: Variant = _selection_center()
	if center == null:
		return
	var target: Vector3 = center
	# 参考平面先跟着目标高度走，否则飞行过程中点选还落在旧高度层
	_projection.set_reference_height(target.y)
	_rig.focus_on(target, false)


## 选中单位的世界坐标中心。候选是裸 Vector3 或带 position 的对象 / 字典，一律吃。
func _selection_center() -> Variant:
	var sum := Vector3.ZERO
	var count := 0
	for candidate in _selection:
		var world: Variant = _candidate_world(candidate)
		if world == null:
			continue
		var point: Vector3 = world
		sum += point
		count += 1
	if count == 0:
		return null
	return sum / float(count)


## 从候选取世界坐标（Vector3 / 字典 / 对象）。与 ViewProjection 内部同口径，
## 但那是私有方法，本层不越界调用。
func _candidate_world(candidate: Variant) -> Variant:
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


## PageUp / PageDown：切换焦点高度层。相机 y 立刻跳层（不做平滑——切层是"校准观感"，
## 插值途中点选会落在两个高度层之间）。
func _change_altitude_layer(step: int) -> void:
	var layer := clampi(_altitude_layer + step, 0, ALTITUDE_LAYERS.size() - 1)
	if layer == _altitude_layer:
		return
	_altitude_layer = layer
	if _rig != null:
		var focus := _rig.focus_position()
		_rig.focus_on(Vector3(focus.x, ALTITUDE_LAYERS[layer], focus.z), true)
		_sync_reference_height()
	altitude_layer_changed.emit(_altitude_layer)
