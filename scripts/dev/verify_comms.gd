extends Node3D

## 回归：右侧通讯播报列（原版 ui/comms.lua 的最小等价物）。
##
## 之前战损通知只是 HUD 左上角一行纯文字，没有头像、没有多条、没有打字机。
## 原版这块是**战场所有反馈的统一出口**（最多 3 条气泡，头像 + 九宫格 + 逐字）。
##
## 本场景验证：不发时有 0 条、战损产生气泡且带机型与头像编号、
## 打字机逐步显字、超量丢最旧、到期自动清空。

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_comms] ==== 通讯播报列 ====")

	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var victim := session.spawn_unit("ou05", Vector3.ZERO, 1)
	var shooter := session.spawn_unit("ou134", Vector3(0.0, 0.0, 400.0), 0)
	_expect(victim != null and shooter != null, "生成两艘单位")
	if victim == null or shooter == null:
		_report()
		return

	var panel := CommsPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.bind_session(session)
	_expect(panel.bubble_count() == 0, "尚无播报时 0 条")

	# 1. 战损 → 产生气泡，文本带机型与编号
	victim.apply_damage(1.0e9)
	session.request_kill(victim.id, shooter.id)
	session.tick(1.0 / 60.0)
	_expect(panel.bubble_count() == 1, "战损产生 1 条播报（实际 %d）" % panel.bubble_count())
	var text := panel.bubble_text(0)
	_info("  气泡文本「%s」" % text)
	_expect(text.contains("ou05"), "文本带机型（%s）" % text)
	_expect(text.contains(str(victim.id)), "文本带单位编号（%s）" % text)

	# 2. 打字机：时间推进后显字数变多
	var first := panel.revealed_length(0)
	panel.advance(0.2)
	var second := panel.revealed_length(0)
	_info("  打字机：%d 字 → %d 字" % [first, second])
	_expect(second > first, "打字机逐字显示（%d → %d）" % [first, second])
	_expect(first < text.length(), "刚开始没有一次性显示完（%d/%d）" % [first, text.length()])

	# 3. 超量丢最旧：连发 5 条只保留 3 条
	for i in 5:
		panel.post("测试消息 %d" % i)
	_expect(panel.bubble_count() == CommsPanel.MAX_BUBBLES,
		"最多保留 %d 条（实际 %d）" % [CommsPanel.MAX_BUBBLES, panel.bubble_count()])
	_expect(panel.bubble_text(panel.bubble_count() - 1).contains("测试消息 4"),
		"最新一条在最下面（%s）" % panel.bubble_text(panel.bubble_count() - 1))

	# 4. 到期清空
	panel.advance(CommsPanel.HOLD_SECONDS + CommsPanel.FADE_SECONDS + 5.0)
	_expect(panel.bubble_count() == 0, "到期后自动清空（剩 %d）" % panel.bubble_count())

	session.shutdown()
	_report()


func _report() -> void:
	print("[verify_comms] ---- 结果 ----")
	print("[verify_comms]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_comms] PASS")
		get_tree().quit(0)
	else:
		print("[verify_comms] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_comms] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_comms]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_comms]   FAIL  %s" % what)
