extends Node3D

## 回归：选中单位面板（旧版 unit_panel 的最小等价物）。
##
## 之前完全没有这个面板 —— 玩家只能靠场上血条猜自己在指挥什么。
## 本场景验证：展开/收起、行内容随选中与血量变化、选中全灭时回退到己方全体。

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_panel] ==== 单位面板 ====")

	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var a := session.spawn_unit("ou05", Vector3.ZERO, 0)
	var b := session.spawn_unit("ou134", Vector3(0.0, 0.0, 500.0), 0)
	_expect(a != null and b != null, "生成两艘己方单位")
	if a == null or b == null:
		_report()
		return

	var panel := UnitPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.bind_session(session)

	_expect(not panel.is_expanded(), "默认收起")
	_expect(not panel.visible, "默认不可见")

	# 1. 选中一艘 → 展开
	GameState.set_selected_units([a])
	panel.toggle()
	_expect(panel.is_expanded(), "toggle 后展开")
	_expect(panel.visible, "展开后可见")
	panel._process(0.016)
	_info("  行数 %d，第 1 行「%s」" % [panel.row_count(), panel.row_text(0)])
	_expect(panel.row_count() == 1, "只显示选中的 1 艘（实际 %d）" % panel.row_count())
	_expect(panel.row_text(0).contains("ou05"),
		"行里有机型名（%s）" % panel.row_text(0))
	_expect(panel.row_text(0).contains("100%"),
		"满血显示 100%%（%s）" % panel.row_text(0))

	# 2. 掉血 → 文本跟着变
	a.hp = a.max_hp * 0.5
	panel._process(0.016)
	_info("  半血后第 1 行「%s」" % panel.row_text(0))
	_expect(panel.row_text(0).contains("50%"),
		"半血显示 50%%（%s）" % panel.row_text(0))

	# 3. 选中单位阵亡 → 回退到己方全体（仍能看到舰队）
	GameState.set_selected_units([])
	panel._process(0.016)
	_info("  清空选中后行数 %d" % panel.row_count())
	_expect(panel.row_count() >= 1,
		"没有选中时显示己方全体（%d 行）" % panel.row_count())

	# 4. 再 toggle → 收起
	panel.toggle()
	_expect(not panel.is_expanded(), "再次 toggle 收起")
	_expect(not panel.visible, "收起后不可见")

	GameState.set_selected_units([])
	session.shutdown()
	_report()


func _report() -> void:
	print("[verify_panel] ---- 结果 ----")
	print("[verify_panel]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_panel] PASS")
		get_tree().quit(0)
	else:
		print("[verify_panel] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_panel] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_panel]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_panel]   FAIL  %s" % what)
