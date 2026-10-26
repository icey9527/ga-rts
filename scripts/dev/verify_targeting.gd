extends Node3D

## 回归：指选模式（原版 start_targeting / cancel_command）。
##
## 之前从菜单选“移动”会**立即下令**，玩家看不到“要把命令下到哪”，
## 这就是“点了按钮没反馈”的主因。现在改成：
##   选菜单 → 进入指选（不立即下令）→ 左键确认 / 右键取消
##
## 本场景验证状态机与信号，不测像素绘制（那属于 UI 视觉，另有人工确认）。

var _checks := 0
var _fails := 0
var _issued: Array = []
var _targeting_events: Array = []


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_target] ==== 指选模式 ====")

	var router := InputRouter.new()
	add_child(router)
	var menu := CommandMenu.new()
	add_child(menu)
	await get_tree().process_frame

	var unit := Unit.new(11, "test")
	unit.alive = true
	unit.position = Vector3.ZERO
	router.set_selection([unit])
	router.set_command_menu(menu)

	var handler := Callable(self, &"_on_command_issued")
	if not CommandBus.command_issued.is_connected(handler):
		CommandBus.command_issued.connect(handler)
	router.targeting_changed.connect(func(active: bool, kind: StringName) -> void:
		_targeting_events.append({"active": active, "kind": kind}))

	# 1. 菜单选“移动” → 进入指选，**不立即下令**
	menu.command_chosen.emit(&"cmd_move", {"point": Vector3(0.0, 0.0, -100.0)})
	_expect(router.targeting_active(), "菜单选移动后进入指选模式")
	_expect(router.targeting_kind() == &"cmd_move",
		"待发命令是 cmd_move（实际 %s）" % router.targeting_kind())
	_expect(router.command_mode() == InputRouter.CommandMode.TARGETING,
		"command_mode 切到 TARGETING")
	_expect(_issued.is_empty(), "**还没有下令**（等玩家点确认）")
	_expect(_targeting_events.size() == 1 and bool(_targeting_events[0]["active"]),
		"targeting_changed 发出 active=true")

	# 2. 右键取消 → 退出指选，仍然不下令
	router._handle_right_click(Vector2(400.0, 300.0))
	_expect(not router.targeting_active(), "右键取消后退出指选")
	_expect(_issued.is_empty(), "取消后也没有下令")
	_expect(_targeting_events.size() == 2 and not bool(_targeting_events[1]["active"]),
		"targeting_changed 发出 active=false")
	if _targeting_events.size() == 2:
		_expect(_targeting_events[1]["kind"] == &"cmd_move",
			"退出时带上被取消的命令种类（%s）" % _targeting_events[1]["kind"])

	# 3. 无需目标的命令（停止）→ 立即执行，不进指选
	menu.command_chosen.emit(&"cmd_stop", {"source": &"test"})
	_expect(not router.targeting_active(), "停止命令不进指选模式")
	_expect(_issued.size() == 1 and _issued[0] == &"cmd_stop",
		"停止命令立即发出（实际 %s）" % str(_issued))

	# 4. 再次进入指选后切别的命令 → 状态正确切换
	menu.command_chosen.emit(&"cmd_attack", {})
	_expect(router.targeting_active() and router.targeting_kind() == &"cmd_attack",
		"可以再次进入指选（攻击）")
	router._set_command_mode(InputRouter.CommandMode.NONE)
	_expect(not router.targeting_active(), "程序化清空也能退出指选")

	await _case_draw_smoke()

	if CommandBus.command_issued.is_connected(handler):
		CommandBus.command_issued.disconnect(handler)

	print("[verify_target] ---- 结果 ----")
	print("[verify_target]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_target] PASS")
		get_tree().quit(0)
	else:
		print("[verify_target] FAIL")
		get_tree().quit(1)


func _on_command_issued(_target: Variant, kind: StringName, _options: Dictionary) -> void:
	_issued.append(kind)


func _header(text: String) -> void:
	print("[verify_target] ---- %s" % text)


## 绘制冒烟：显式调一次 _draw。
##
## 为什么必须单独测：**无头模式不渲染，引擎永远不会调 _draw**。
## 所以 `_draw` 里的 API 误用（曾把 ViewProjection.is_visible 写成
## is_position_behind）在整套无头回归里一次都不会执行 ——
## 实际运行时却每帧报 Invalid call，而且 _draw 在第一艘单位处就中断，
## 箭头与准星一帧都画不出来（玩家看到的就是“没有箭头”）。
## 直调 _draw 能让这类错误在无头回归里就暴露（脚本错误会打到 stderr）。
func _case_draw_smoke() -> void:
	_header("绘制冒烟：显式调用 _draw")
	var packed := load("res://scenes/camera/rts_camera.tscn") as PackedScene
	if packed == null:
		_expect(false, "加载相机场景")
		return
	var rig := packed.instantiate() as RtsCameraRig
	add_child(rig)
	await get_tree().process_frame
	rig.force_mode(RtsCameraRig.ViewMode.VIEW_3D)
	rig.focus_on(Vector3.ZERO, true)

	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var unit := session.spawn_unit("ou05", Vector3(0.0, 0.0, -500.0), 0)
	_expect(unit != null, "生成一艘单位")
	if unit == null:
		session.shutdown()
		return

	var router := InputRouter.new()
	add_child(router)
	router.set_selection([unit])
	router._enter_targeting(InputRouter.CMD_MOVE)

	var overlay := TargetingOverlay.new()
	add_child(overlay)
	overlay.bind(router, session, rig.view_projection())
	await get_tree().process_frame

	overlay._draw()
	_expect(router.targeting_active(), "_draw 跑通且没打断指选态")
	session.shutdown()


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_target]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_target]   FAIL  %s" % what)
