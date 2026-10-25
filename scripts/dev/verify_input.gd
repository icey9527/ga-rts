extends Node3D

## T-1.3 输入路由验证场景（开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path F:\godot\ga-rts \
##         res://scenes/dev/verify_input.tscn
##     通过 → exit 0    失败 → exit 1
##
## 纪律：**所有输入都用 Input.parse_input_event() 构造真实 InputEvent**，走
## InputRouter._unhandled_input 这条真正的入口；不直接调它的私有方法，否则验证的是
## "我以为它会怎么算"，而不是"引擎真的把事件送对了吗"。
##
## 覆盖 8 个用例（T-1.3 验收点）：
##   1. 左键点选（3 个假候选单位，点中一个 → selection 只有它，信号一次）
##   2. 左键拖拽 20 px → 框选路径（box_select_changed 触发，且不走点选）
##   3. 右键点击（位移 2 px < 阈值 4 px）→ cmd_move，且相机焦点不动
##   4. 右键拖拽 30 px → 相机焦点移动，且不发 cmd_move
##   5. A 键短按后左键点击 → cmd_attack_move（不是 cmd_move）
##   6. Tab 切模式 → view_mode 切换，焦点位置保持
##   7. S 键短按 → cmd_stop
##   8. PageUp / PageDown → altitude_layer() 在 0/1/2 之间且不越界
##
## 关于注入坐标系：headless 下窗口默认 64×64，而 project.godot 的 canvas_items 拉伸
## 会把事件坐标按 final_transform 放大 18 倍再送进 _unhandled_input（实测 500 → 9000）。
## 所以本场景先把窗口固定成 content_scale_size 并关掉拉伸，让注入坐标 1:1 到达，
## 并用一条断言把这个前提钉死（final_transform 必须是单位阵）。

## 注入坐标系尺寸。与关掉拉伸后的窗口一致，事件坐标不做任何缩放。
const VIEWPORT_SIZE := Vector2i(1152, 648)
## 浮点比较容差（焦点"没动"的判据）
const EPSILON := 1.0e-4
## 右键拖拽 30 px 后焦点至少移动这么多米（低于它说明相机根本没动）
const MIN_PAN_METERS := 1.0
## 命令落点与 screen_to_world 的比对容差（米）
const POINT_TOLERANCE := 0.01
## 假候选单位的初始屏幕位置（保证都在视口内、且彼此远离 pick_radius）
const UNIT_SCREEN_POINTS := [
	Vector2(300.0, 200.0),
	Vector2(576.0, 324.0),
	Vector2(830.0, 405.0),
]
## 空地点击点（离所有假单位都超过 pick_radius = 18 px）
const EMPTY_CLICK := Vector2(576.0, 560.0)
## A + 左键的落点（同样是空地）
const ATTACK_CLICK := Vector2(700.0, 560.0)
## 右键拖拽的起点（同样是空地）
const RIGHT_DRAG_START := Vector2(400.0, 500.0)

@onready var camera_rig: RtsCameraRig = $CameraRig
@onready var router: InputRouter = $InputRouter
@onready var units_root: Node3D = $Units

## 双视图唯一投影（与 InputRouter 共用 rig.view_projection() 的同一个实例）
var _projection: ViewProjection = null
## 假候选单位（Node3D，带 global_position，正好命中 ViewProjection 的宽容取坐标）
var _units: Array = []

var _checks := 0
var _failures: Array[String] = []

# ---------------------------------------------------------------- 信号采集
var _selection_events: Array = []
var _box_events: Array = []
var _command_mode_events: Array = []
var _altitude_events: Array = []
var _commands: Array = []


func _ready() -> void:
	_configure_window()
	# 等一帧：窗口尺寸 / 拉伸设置落地，子节点的 _ready 与相机装配也先跑完
	await get_tree().process_frame

	_projection = camera_rig.view_projection()
	router.setup(camera_rig, _projection)
	_reset_camera_state()
	_spawn_units()
	router.set_candidates(_units)
	_connect_signals()

	_test_environment()

	await _test_1_click_select()
	await _test_2_drag_box_select()
	await _test_3_right_click_move()
	await _test_4_right_drag_pan()
	await _test_5_attack_move()
	await _test_6_tab_view_mode()
	await _test_7_stop()
	await _test_8_altitude_layers()

	_report()


# ---------------------------------------------------------------- 环境

## headless 下让注入的鼠标坐标 1:1 到达 _unhandled_input。
func _configure_window() -> void:
	var window := get_window()
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_factor = 1.0
	window.size = VIEWPORT_SIZE
	# 同帧注入的多个 motion 不得被合并（否则拖拽路径只剩最后一帧位移）
	Input.use_accumulated_input = false


func _spawn_units() -> void:
	_units.clear()
	for i in UNIT_SCREEN_POINTS.size():
		var unit := Node3D.new()
		unit.name = "FakeUnit%d" % i
		units_root.add_child(unit)
		# 用屏幕坐标反推世界坐标：位置由投影说了算，之后点选 / 框选的坐标才可靠
		unit.global_position = _projection.screen_to_world(UNIT_SCREEN_POINTS[i])
		_units.append(unit)


func _connect_signals() -> void:
	router.selection_changed.connect(_on_selection_changed)
	router.box_select_changed.connect(_on_box_select_changed)
	router.command_mode_changed.connect(_on_command_mode_changed)
	router.altitude_layer_changed.connect(_on_altitude_layer_changed)
	CommandBus.command_issued.connect(_on_command_issued)


func _test_environment() -> void:
	_header("0. 环境：注入坐标系 / 依赖装配")
	_expect(_projection != null and _projection.is_ready(), "ViewProjection 已就绪")
	var size := _projection.viewport_size()
	_expect(size.is_equal_approx(Vector2(VIEWPORT_SIZE)),
		"视口 %s = 注入坐标系 %s" % [_v2(size), _v2(Vector2(VIEWPORT_SIZE))])
	_expect(get_viewport().get_final_transform().is_equal_approx(Transform2D.IDENTITY),
		"final_transform 为单位阵（注入坐标 1:1 到达）")
	_expect(not camera_rig.camera_3d.accept_input and not camera_rig.camera_2d.accept_input,
		"相机自带输入已关闭（accept_input=false）")
	_expect(router.is_ready(), "InputRouter 已注入 rig + projection")
	var viewport_rect := Rect2(Vector2.ZERO, size).grow(-4.0)
	for i in _units.size():
		var screen := _projection.world_to_screen((_units[i] as Node3D).global_position)
		_expect(viewport_rect.has_point(screen),
			"FakeUnit%d 投影在视口内 %s" % [i, _v2(screen)])


# ---------------------------------------------------------------- 用例 1：点选

func _test_1_click_select() -> void:
	_header("1. 左键点选")
	_prepare()
	var target: Node3D = _units[1]
	var screen := _projection.world_to_screen(target.global_position)
	print("[verify_input]   点 FakeUnit1 @ 屏幕 %s" % _v2(screen))

	await _click(screen)

	var picked: Array = router.selection()
	_expect(picked.size() == 1, "selection() 只有 1 个（实际 %d）" % picked.size())
	_expect(picked.size() == 1 and picked[0] == target,
		"选中的是点中的那个（实际 %s，期望 FakeUnit1）" % _unit_names(picked))
	_expect(_selection_events.size() == 1,
		"selection_changed 触发 %d 次（期望 1）" % _selection_events.size())


# ---------------------------------------------------------------- 用例 2：框选

func _test_2_drag_box_select() -> void:
	_header("2. 左键拖拽 20 px → 框选路径（不得点选）")
	_prepare()
	# 关键设计：松手点离 FakeUnit2 只有 10 px（点选一定会命中它），但框选的矩形
	# 往左收了 10 px（FakeUnit2 在矩形外）。于是"走了点选"与"走了框选"的 selection
	# 必然不同 —— 这是本用例唯一能区分两条路径的观测量。
	var unit2_screen := _projection.world_to_screen((_units[2] as Node3D).global_position)
	var release := unit2_screen - Vector2(10.0, 0.0)
	var start := release - Vector2(20.0, 5.0)
	var rect := Rect2(start, release - start)
	var click_would_hit: Variant = _projection.pick_point(release, _units)
	var expected_box := _projection.pick_rect(rect, _units)
	print("[verify_input]   按下 %s → 松开 %s（位移 %.1f px），框 %s" % [
		_v2(start), _v2(release), start.distance_to(release), _rect(rect)])
	print("[verify_input]   松手点点选会命中 %s；该矩形框选应得 %d 个" % [
		_hit_name(click_would_hit), expected_box.size()])

	Input.parse_input_event(_button_event(MOUSE_BUTTON_LEFT, true, start))
	Input.parse_input_event(_motion_event(release, release - start))
	Input.parse_input_event(_button_event(MOUSE_BUTTON_LEFT, false, release))
	await _settle()

	var picked: Array = router.selection()
	var active_events := 0
	for event in _box_events:
		if bool(event["active"]):
			active_events += 1

	print("[verify_input]   box_select_changed %d 次（拖拽中 %d 次，结束 1 次）" % [
		_box_events.size(), active_events])
	_expect(_box_events.size() == 2, "box_select_changed 触发 2 次（实际 %d：1 次 active + 1 次结束）" % _box_events.size())
	_expect(active_events == 1, "拖拽中 active=true 触发 %d 次（期望 1）" % active_events)
	_expect(not _box_events.is_empty() and not bool(_box_events.back()["active"]),
		"最后一次 box_select_changed 是 active=false（框选结束）")
	_expect(not _box_events.is_empty() and (_box_events.back()["rect"] as Rect2).is_equal_approx(rect),
		"结束时的框 %s = 按下→松开矩形 %s" % [
			_rect(_box_events.back()["rect"] if not _box_events.is_empty() else Rect2()), _rect(rect)])

	_expect(click_would_hit == _units[2], "松手位置的点选命中 = FakeUnit2（说明点选路径本会选中它）")
	_expect(picked.is_empty(), "框选结果为空（实际 %d 个：%s）" % [picked.size(), _unit_names(picked)])
	_expect(_same_units(picked, expected_box), "selection() = pick_rect(矩形)（框选语义，而不是点选语义）")
	_expect(not (picked.size() == 1 and picked[0] == _units[2]),
		"未走点选：selection 不是 [FakeUnit2]")


# ---------------------------------------------------------------- 用例 3：右键点击 = 移动命令

func _test_3_right_click_move() -> void:
	_header("3. 右键点击（位移 2 px，小于阈值 4 px）")
	_prepare()
	router.set_selection([_units[0]])
	_clear_counters()

	var focus_before := camera_rig.focus_position()
	var release := EMPTY_CLICK + Vector2(2.0, 0.0)
	Input.parse_input_event(_button_event(MOUSE_BUTTON_RIGHT, true, EMPTY_CLICK))
	Input.parse_input_event(_motion_event(release, Vector2(2.0, 0.0)))
	Input.parse_input_event(_button_event(MOUSE_BUTTON_RIGHT, false, release))
	await _settle()
	var focus_after := camera_rig.focus_position()

	_expect(_count_kind(InputRouter.CMD_MOVE) == 1,
		"cmd_move 发出 %d 次（期望 1）" % _count_kind(InputRouter.CMD_MOVE))
	_expect(focus_after.distance_to(focus_before) < EPSILON,
		"焦点 %s -> %s  未平移" % [_v3(focus_before), _v3(focus_after)])
	_expect(_selection_events.is_empty(), "右键点击不改变选择（selection_changed %d 次）" % _selection_events.size())

	var cmd := _last_command_of(InputRouter.CMD_MOVE)
	_expect(not cmd.is_empty(), "命令记录到 target / kind / options")
	if not cmd.is_empty():
		var options: Dictionary = cmd["options"]
		var expected_point := _projection.screen_to_world(release)
		_expect(options.has("point") and options.has("screen") and options.has("layer") and options.has("source"),
			"options 键齐全（point/screen/layer/source）")
		_expect((options["point"] as Vector3).distance_to(expected_point) < POINT_TOLERANCE,
			"落点 %s = screen_to_world(%s) %s" % [
				_v3(options["point"]), _v2(release), _v3(expected_point)])
		_expect((options["screen"] as Vector2).is_equal_approx(release),
			"screen = 松手像素 %s（实际 %s）" % [_v2(release), _v2(options["screen"])])
		_expect(int(options["layer"]) == 1, "layer = %d（期望 1 = L1）" % int(options["layer"]))
		_expect(StringName(options["source"]) == InputRouter.COMMAND_SOURCE,
			"source = %s（期望 %s）" % [String(options["source"]), String(InputRouter.COMMAND_SOURCE)])
		var target_list: Array = cmd["target"]
		_expect(target_list.size() == 1 and target_list[0] == _units[0],
			"命令目标 = 当前选中列表 %s" % _unit_names(target_list))


# ---------------------------------------------------------------- 用例 4：右键拖拽 = 相机平移

func _test_4_right_drag_pan() -> void:
	_header("4. 右键拖拽 30 px → 相机平移，不发命令")
	_prepare()
	# 选中非空：万一误发移动命令，_issue() 会成功，断言才抓得住
	router.set_selection([_units[0]])
	_clear_counters()

	var focus_before := camera_rig.focus_position()
	var release := RIGHT_DRAG_START + Vector2(30.0, 0.0)
	Input.parse_input_event(_button_event(MOUSE_BUTTON_RIGHT, true, RIGHT_DRAG_START))
	Input.parse_input_event(_motion_event(release, Vector2(30.0, 0.0)))
	Input.parse_input_event(_button_event(MOUSE_BUTTON_RIGHT, false, release))
	await _settle()
	var focus_after := camera_rig.focus_position()
	var moved := focus_after.distance_to(focus_before)

	_expect(moved > MIN_PAN_METERS,
		"焦点 %s -> %s（移动 %.2f m > %.1f）" % [_v3(focus_before), _v3(focus_after), moved, MIN_PAN_METERS])
	_expect(_count_kind(InputRouter.CMD_MOVE) == 0,
		"未发 cmd_move（实际 %d 次）" % _count_kind(InputRouter.CMD_MOVE))
	_expect(_commands.is_empty(),
		"未发任何命令（实际 %d 条：%s）" % [_commands.size(), _kind_names()])


# ---------------------------------------------------------------- 用例 5：A + 左键 = 攻击移动

func _test_5_attack_move() -> void:
	_header("5. A 键（短按）后左键点击 → cmd_attack_move")
	_prepare()
	router.set_selection([_units[0]])
	_clear_counters()

	var focus_before := camera_rig.focus_position()
	await _tap_key(KEY_A)
	print("[verify_input]   A 短按后 command_mode = %s" % _command_mode_name(router.command_mode()))
	_expect(router.command_mode() == InputRouter.CommandMode.ATTACK_MOVE,
		"command_mode = %s（期望 ATTACK_MOVE）" % _command_mode_name(router.command_mode()))
	_expect(_command_mode_events.size() == 1 and int(_command_mode_events[0]) == InputRouter.CommandMode.ATTACK_MOVE,
		"command_mode_changed 触发 %d 次 -> %s" % [
			_command_mode_events.size(), _command_mode_names(_command_mode_events)])
	_expect(camera_rig.focus_position().distance_to(focus_before) < EPSILON,
		"短按 A 不平移相机（焦点 %s -> %s）" % [_v3(focus_before), _v3(camera_rig.focus_position())])

	await _click(ATTACK_CLICK)
	_expect(_count_kind(InputRouter.CMD_ATTACK_MOVE) == 1,
		"cmd_attack_move 发出 %d 次（期望 1）" % _count_kind(InputRouter.CMD_ATTACK_MOVE))
	_expect(_count_kind(InputRouter.CMD_MOVE) == 0,
		"未发 cmd_move（实际 %d 次）" % _count_kind(InputRouter.CMD_MOVE))
	_expect(router.command_mode() == InputRouter.CommandMode.NONE,
		"落点后 command_mode 回到 NONE（实际 %s）" % _command_mode_name(router.command_mode()))
	_expect(_selection_events.is_empty(),
		"待落点左键不改变选择（selection_changed %d 次）" % _selection_events.size())

	var cmd := _last_command_of(InputRouter.CMD_ATTACK_MOVE)
	if not cmd.is_empty():
		var options: Dictionary = cmd["options"]
		_expect((options["point"] as Vector3).distance_to(_projection.screen_to_world(ATTACK_CLICK)) < POINT_TOLERANCE,
			"攻击移动落点 %s = screen_to_world(%s)" % [_v3(options["point"]), _v2(ATTACK_CLICK)])


# ---------------------------------------------------------------- 用例 6：Tab 切模式

func _test_6_tab_view_mode() -> void:
	_header("6. Tab 切模式（3D → 2D → 3D），焦点保持")
	_prepare()
	var mode_before := camera_rig.mode()
	var focus_before := camera_rig.focus_position()
	await _tap_key(KEY_TAB)
	var mode_after := camera_rig.mode()
	var focus_after := camera_rig.focus_position()

	print("[verify_input]   view_mode %s -> %s，焦点 %s -> %s" % [
		_view_mode_name(mode_before), _view_mode_name(mode_after), _v3(focus_before), _v3(focus_after)])
	_expect(mode_before == RtsCameraRig.ViewMode.VIEW_3D and mode_after == RtsCameraRig.ViewMode.VIEW_2D,
		"view_mode %s -> %s（期望 VIEW_3D -> VIEW_2D）" % [_view_mode_name(mode_before), _view_mode_name(mode_after)])
	_expect(focus_after.distance_to(focus_before) < EPSILON,
		"焦点 %s -> %s  保持" % [_v3(focus_before), _v3(focus_after)])
	_expect(_projection.is_orthographic(), "ViewProjection 已重绑到正交相机")

	var focus_before_back := camera_rig.focus_position()
	await _tap_key(KEY_TAB)
	_expect(camera_rig.mode() == RtsCameraRig.ViewMode.VIEW_3D,
		"再按 Tab 回到 VIEW_3D（实际 %s）" % _view_mode_name(camera_rig.mode()))
	_expect(camera_rig.focus_position().distance_to(focus_before_back) < EPSILON,
		"切回 3D 焦点 %s -> %s 保持" % [_v3(focus_before_back), _v3(camera_rig.focus_position())])
	_expect(not _projection.is_orthographic(), "ViewProjection 重绑回透视相机")


# ---------------------------------------------------------------- 用例 7：S = 停止

func _test_7_stop() -> void:
	_header("7. S 键（短按）→ cmd_stop")
	_prepare()
	router.set_selection([_units[0], _units[1]])
	_clear_counters()

	var focus_before := camera_rig.focus_position()
	await _tap_key(KEY_S)
	var focus_after := camera_rig.focus_position()

	_expect(_count_kind(InputRouter.CMD_STOP) == 1,
		"cmd_stop 发出 %d 次（期望 1）" % _count_kind(InputRouter.CMD_STOP))
	_expect(_commands.size() == 1,
		"只发了 1 条命令（实际 %d 条：%s）" % [_commands.size(), _kind_names()])
	_expect(focus_after.distance_to(focus_before) < EPSILON,
		"短按 S 不平移相机（焦点 %s -> %s）" % [_v3(focus_before), _v3(focus_after)])
	var cmd := _last_command_of(InputRouter.CMD_STOP)
	if not cmd.is_empty():
		var target_list: Array = cmd["target"]
		_expect(target_list.size() == 2 and target_list[0] == _units[0] and target_list[1] == _units[1],
			"停止命令目标 = 全部选中单位 %s" % _unit_names(target_list))


# ---------------------------------------------------------------- 用例 8：高度层

func _test_8_altitude_layers() -> void:
	_header("8. PageUp / PageDown 高度层（0/1/2，不越界）")
	_prepare()
	var start_layer := router.altitude_layer()
	_expect(start_layer == 1, "初始层 = %d（期望 1 = L1）" % start_layer)

	var taps: Array[Key] = [KEY_PAGEUP, KEY_PAGEUP, KEY_PAGEDOWN, KEY_PAGEDOWN, KEY_PAGEDOWN]
	var observed: Array = []
	for code in taps:
		await _tap_key(code)
		var layer := router.altitude_layer()
		observed.append(layer)
		var focus_y := camera_rig.focus_position().y
		var expected_y := InputRouter.ALTITUDE_LAYERS[layer]
		print("[verify_input]   %s → 层 %d（焦点 y=%.1f，参考平面 y=%.1f）" % [
			_key_name(code), layer, focus_y, _projection.reference_height()])
		_expect(layer >= 0 and layer <= 2,
			"%s 后层索引 %d 在 0..2 内（不越界）" % [_key_name(code), layer])
		_expect(is_equal_approx(focus_y, expected_y),
			"%s 后焦点 y=%.1f = ALTITUDE_LAYERS[%d]=%.1f" % [_key_name(code), focus_y, layer, expected_y])
		_expect(is_equal_approx(_projection.reference_height(), expected_y),
			"%s 后投影参考平面 y=%.1f（跟随焦点高度层）" % [_key_name(code), _projection.reference_height()])

	print("[verify_input]   层序列 %s（期望 [2, 2, 1, 0, 0]）" % str(observed))
	_expect(_same_ints(observed, [2, 2, 1, 0, 0]),
		"层序列 = %s（期望 [2, 2, 1, 0, 0]）" % str(observed))
	_expect(_same_ints(_altitude_events, [2, 1, 0]),
		"altitude_layer_changed 只在实际换层时触发：%s（期望 [2, 1, 0]）" % str(_altitude_events))


# ---------------------------------------------------------------- 用例准备

## 每个用例都从同一台默认机位、同一份干净路由状态出发，输出才好读。
func _prepare() -> void:
	_reset_camera_state()
	router.reset()
	router.set_candidates(_units)
	CommandBus.drain()
	_clear_counters()


func _reset_camera_state() -> void:
	if camera_rig.mode() != RtsCameraRig.ViewMode.VIEW_3D:
		camera_rig.set_mode(RtsCameraRig.ViewMode.VIEW_3D)
	var cam := camera_rig.camera_3d
	cam.snap_focus(Vector3.ZERO)
	cam.set_yaw_degrees(0.0)
	cam.set_pitch_degrees(RtsCamera3D.DEFAULT_PITCH_DEG)
	cam.zoom_to(RtsCamera3D.DEFAULT_DISTANCE, true)
	_projection.set_reference_height(cam.focus_position.y)


func _clear_counters() -> void:
	_selection_events.clear()
	_box_events.clear()
	_command_mode_events.clear()
	_altitude_events.clear()
	_commands.clear()


# ---------------------------------------------------------------- 事件注入

## 一次点击 = 按下 + 松开，同一帧 flush，中间没有任何 motion（位移 0）。
func _click(screen_pos: Vector2, button := MOUSE_BUTTON_LEFT) -> void:
	Input.parse_input_event(_button_event(button, true, screen_pos))
	Input.parse_input_event(_button_event(button, false, screen_pos))
	await _settle()


## 一次短按 = 按下 + 松开同一帧（A / S 的 AMBIGUOUS_HOLD_MS 判定必然是"短按"）。
func _tap_key(code: Key) -> void:
	Input.parse_input_event(_key_event(code, true))
	Input.parse_input_event(_key_event(code, false))
	await _settle()


## 过一帧：注入的事件在下一帧开头 flush，flush 时同步派发到 _unhandled_input。
func _settle() -> void:
	await get_tree().process_frame


func _button_event(index: MouseButton, pressed: bool, screen_pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = screen_pos
	event.global_position = screen_pos
	return event


func _motion_event(screen_pos: Vector2, relative: Vector2) -> InputEventMouseMotion:
	var event := InputEventMouseMotion.new()
	event.position = screen_pos
	event.global_position = screen_pos
	event.relative = relative
	return event


func _key_event(code: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	return event


# ---------------------------------------------------------------- 信号回调

func _on_selection_changed(units: Array) -> void:
	_selection_events.append(units.duplicate())


func _on_box_select_changed(screen_rect: Rect2, active: bool) -> void:
	_box_events.append({"rect": screen_rect, "active": active})


func _on_command_mode_changed(mode: int) -> void:
	_command_mode_events.append(mode)


func _on_altitude_layer_changed(layer_index: int) -> void:
	_altitude_events.append(layer_index)


func _on_command_issued(unit_or_group: Variant, kind: StringName, options: Dictionary) -> void:
	var target: Variant = unit_or_group
	if target is Array:
		target = (target as Array).duplicate()
	_commands.append({"target": target, "kind": kind, "options": options.duplicate(true)})


# ---------------------------------------------------------------- 命令查询

func _count_kind(kind: StringName) -> int:
	var count := 0
	for command in _commands:
		if command["kind"] == kind:
			count += 1
	return count


func _last_command_of(kind: StringName) -> Dictionary:
	for i in range(_commands.size() - 1, -1, -1):
		if _commands[i]["kind"] == kind:
			return _commands[i]
	return {}


func _kind_names() -> String:
	var names: Array[String] = []
	for command in _commands:
		names.append(String(command["kind"]))
	return ", ".join(names) if not names.is_empty() else "无"


# ---------------------------------------------------------------- 比较 / 打印

func _same_units(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


func _same_ints(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if int(a[i]) != int(b[i]):
			return false
	return true


func _unit_names(units: Array) -> String:
	if units.is_empty():
		return "空"
	var names: Array[String] = []
	for unit in units:
		names.append((unit as Node).name if unit is Node else str(unit))
	return "[" + ", ".join(names) + "]"


func _hit_name(hit: Variant) -> String:
	if hit == null:
		return "空地"
	if hit is Node:
		return (hit as Node).name
	return str(hit)


## 两套 enum 的数值会撞（ViewMode.VIEW_2D == CommandMode.ATTACK_MOVE == 1），
## 所以视图模式与命令模式必须分开格式化，否则打印出来的名字会骗人。
func _view_mode_name(mode: int) -> String:
	match mode:
		RtsCameraRig.ViewMode.VIEW_3D:
			return "VIEW_3D"
		RtsCameraRig.ViewMode.VIEW_2D:
			return "VIEW_2D"
	return "UNKNOWN(%d)" % mode


func _command_mode_name(mode: int) -> String:
	match mode:
		InputRouter.CommandMode.NONE:
			return "NONE"
		InputRouter.CommandMode.ATTACK_MOVE:
			return "ATTACK_MOVE"
		InputRouter.CommandMode.CHANGE_ALTITUDE:
			return "CHANGE_ALTITUDE"
	return "UNKNOWN(%d)" % mode


func _command_mode_names(modes: Array) -> String:
	var names: Array[String] = []
	for mode in modes:
		names.append(_command_mode_name(int(mode)))
	return "[" + ", ".join(names) + "]"


func _key_name(code: Key) -> String:
	match code:
		KEY_PAGEUP:
			return "PageUp"
		KEY_PAGEDOWN:
			return "PageDown"
	return OS.get_keycode_string(code)


func _v2(v: Vector2) -> String:
	return "(%.1f, %.1f)" % [v.x, v.y]


func _v3(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]


func _rect(r: Rect2) -> String:
	return "[%s .. %s]" % [_v2(r.position), _v2(r.end)]


func _header(title: String) -> void:
	print("[verify_input] ---- %s" % title)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	var verdict := "PASS" if condition else "FAIL"
	if not condition:
		_failures.append(label)
	print("[verify_input]   %s  %s" % [label, verdict])


func _report() -> void:
	print("[verify_input] ---- 结果 ----")
	print("[verify_input]   断言 %d 条，失败 %d 条" % [_checks, _failures.size()])
	if _failures.is_empty():
		print("[verify_input] PASS")
		get_tree().quit(0)
		return
	for line in _failures:
		print("[verify_input]   失败：%s" % line)
	print("[verify_input] FAIL")
	get_tree().quit(1)
