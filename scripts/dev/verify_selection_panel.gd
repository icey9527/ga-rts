extends Node3D

## 回归：右下单位详情面板（原版 ui/selection_panel.lua 的最小等价物）。
##
## 之前没有这块 —— 玩家选中一艘船后，除了头顶血条看不到任何数值。
## 本场景验证：无选中时隐藏、单选显示机型/高度/状态/目标、多选切编队视图、
## 单位阵亡后自动隐藏。
##
## 注意：原版的 EN（能量）/SP（必杀条）对应系统还没做，
## 面板刻意不画空条 —— 一条永远空的进度条比没有更误导。

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_selpanel] ==== 右下详情面板 ====")

	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var a := session.spawn_unit("ou05", Vector3(0.0, 80.0, 0.0), 0)
	var b := session.spawn_unit("ou134", Vector3(0.0, 0.0, 500.0), 0)
	_expect(a != null and b != null, "生成两艘己方单位")
	if a == null or b == null:
		_report()
		return

	var panel := SelectionPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.bind_session(session)

	# 1. 无选中 → 隐藏
	GameState.set_selected_units([])
	panel._process(0.016)
	_expect(not panel.is_showing(), "没有选中时不显示")

	# 2. 单选 → 显示机型 / 高度 / 状态 / 目标
	GameState.set_selected_units([a])
	panel._process(0.016)
	_info("  标题「%s」副标题「%s」明细「%s」" % [
		panel.title_text(), panel.subtitle_text(), panel.detail_text()])
	_expect(panel.is_showing(), "单选时显示")
	_expect(panel.title_text() == "ou05", "标题是机型 ID（%s）" % panel.title_text())
	_expect(panel.subtitle_text().contains("高度"), "副标题带高度（%s）" % panel.subtitle_text())
	_expect(panel.detail_text().contains("目标"), "明细带目标（%s）" % panel.detail_text())

	# 3. 状态变化会反映到副标题（用状态机字段直接改，测的是面板只读展示）
	a.state = UnitStates.State.ATTACKING
	panel._process(0.016)
	_info("  改成 ATTACKING 后副标题「%s」" % panel.subtitle_text())
	_expect(panel.subtitle_text().contains("ATTACKING"),
		"状态变化反映到面板（%s）" % panel.subtitle_text())

	# 4. 多选 → 编队视图
	GameState.set_selected_units([a, b])
	panel._process(0.016)
	_info("  多选：标题「%s」副标题「%s」" % [panel.title_text(), panel.subtitle_text()])
	_expect(panel.title_text() == "编队选择", "多选切到编队视图（%s）" % panel.title_text())
	_expect(panel.subtitle_text().contains("2"), "显示编队数量（%s）" % panel.subtitle_text())

	# 5. 选中单位全部阵亡 → 隐藏（不显示一艘已经没了的船）
	GameState.set_selected_units([])
	panel._process(0.016)
	_expect(not panel.is_showing(), "清空选中后隐藏")

	session.shutdown()
	_report()


func _report() -> void:
	print("[verify_selpanel] ---- 结果 ----")
	print("[verify_selpanel]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_selpanel] PASS")
		get_tree().quit(0)
	else:
		print("[verify_selpanel] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_selpanel] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_selpanel]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_selpanel]   FAIL  %s" % what)
