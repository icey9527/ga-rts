extends Node3D

## 回归：四层舰队 AI（AIDirector）。
##
## 原来只有 SimpleAI（"打最近的"），两场战斗就能被看穿。
## 本场景验证四层里可判定的三条：
##   · 集火层：先打**残血**（低分），不是先打最近的
##   · 集火层：母舰加权 —— HP 明显更高也会被优先集火
##   · 集火层：**滞回** —— 分数接近时不换目标（防全队火力横跳）
##   · 战略层：我方压倒性优势 → aggressive；明显劣势 → defensive
##
## 不测执行层的具体命令：那是 CommandBus 的行为，verify_input/death 已覆盖。

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_aidir] ==== 四层舰队 AI ====")
	_case_focus_prefers_weak()
	_case_mothership_bonus()
	_case_focus_hysteresis()
	_case_strategy()
	_report()


# ---------------------------------------------------------------- 用例

func _case_focus_prefers_weak() -> void:
	_header("1. 集火层：优先残血，不是优先最近")
	var session := _new_session()
	# AI 是 team 1；必须先有自家单位，否则 tick() 会在“舰队为空”处直接返回
	session.spawn_unit("ou134", Vector3(0.0, 0.0, -3000.0), 1)
	# 近处满血、远处残血 —— "打最近的"会选近处，正确的集火应该选残血
	var near := session.spawn_unit("ou05", Vector3(0.0, 0.0, 500.0), 0)
	var far := session.spawn_unit("ou05", Vector3(0.0, 0.0, 3000.0), 0)
	_expect(near != null and far != null, "生成两个敌方目标")
	if near == null or far == null:
		session.shutdown()
		return
	near.hp = near.max_hp          # 满血
	far.hp = far.max_hp * 0.15     # 残血

	var ai := AIDirector.new(1)
	ai.tick(session, AIDirector.REACTION_INTERVAL + 0.01)
	_info("  近处 hp=%.0f 远处 hp=%.0f → 集火 #%d" % [near.hp, far.hp, ai.focus_target_id()])
	_expect(ai.focus_target_id() == far.id,
		"集火残血目标 #%d（实际 #%d）" % [far.id, ai.focus_target_id()])
	session.shutdown()


func _case_mothership_bonus() -> void:
	_header("2. 集火层：母舰加权（HP 更高也会被优先）")
	var session := _new_session()
	session.spawn_unit("ou134", Vector3(0.0, 0.0, -3000.0), 1)
	var frigate := session.spawn_unit("fighter", Vector3(0.0, 0.0, 500.0), 0)
	var mother := session.spawn_unit("mothership", Vector3(0.0, 0.0, 3000.0), 0)
	_expect(frigate != null and mother != null, "生成护卫机与母舰")
	if frigate == null or mother == null:
		session.shutdown()
		return
	frigate.hp = frigate.max_hp
	# 母舰血量压到"扣掉加权后仍然更低"的水平，才能证明加权生效
	mother.hp = mother.max_hp * 0.4

	var ai := AIDirector.new(1)
	ai.tick(session, AIDirector.REACTION_INTERVAL + 0.01)
	_info("  护卫机 hp=%.0f 母舰 hp=%.0f → 集火 #%d" % [
		frigate.hp, mother.hp, ai.focus_target_id()])
	_expect(ai.focus_target_id() == mother.id,
		"集火母舰 #%d（实际 #%d）" % [mother.id, ai.focus_target_id()])
	session.shutdown()


func _case_focus_hysteresis() -> void:
	_header("3. 集火层：滞回（分数接近时不换目标）")
	var session := _new_session()
	session.spawn_unit("ou134", Vector3(0.0, 0.0, -3000.0), 1)
	var a := session.spawn_unit("ou05", Vector3(0.0, 0.0, 500.0), 0)
	var b := session.spawn_unit("ou05", Vector3(0.0, 0.0, 3000.0), 0)
	if a == null or b == null:
		_expect(false, "生成两个目标")
		session.shutdown()
		return
	a.hp = a.max_hp
	b.hp = b.max_hp * 0.5   # b 更残 → 首轮应选 b

	var ai := AIDirector.new(1)
	ai.tick(session, AIDirector.REACTION_INTERVAL + 0.01)
	var first := ai.focus_target_id()
	_expect(first == b.id, "首轮集火残血的 #%d（实际 #%d）" % [b.id, first])

	# 让 a 反超一点点（差距 < 滞回）→ 不该换目标
	a.hp = b.hp - AIDirector.FOCUS_HYSTERESIS * 0.3
	ai.tick(session, AIDirector.REACTION_INTERVAL + 0.01)
	_info("  a 反超 %.0f 后仍集火 #%d" % [b.hp - a.hp, ai.focus_target_id()])
	_expect(ai.focus_target_id() == first,
		"分数接近时不换目标（实际 #%d）" % ai.focus_target_id())

	# 反超超过滞回 → 应该换
	a.hp = b.hp - AIDirector.FOCUS_HYSTERESIS * 3.0
	ai.tick(session, AIDirector.REACTION_INTERVAL + 0.01)
	_info("  a 大幅反超后集火 #%d" % ai.focus_target_id())
	_expect(ai.focus_target_id() == a.id,
		"差距超过滞回时换目标 #%d（实际 #%d）" % [a.id, ai.focus_target_id()])
	session.shutdown()


func _case_strategy() -> void:
	_header("4. 战略层：力量对比 → 攻/守")
	# 强：三艘重巡打一艘小飞机
	var strong := _new_session()
	for i in 3:
		strong.spawn_unit("heavy", Vector3(float(i) * 300.0, 0.0, 0.0), 1)
	strong.spawn_unit("light", Vector3(0.0, 0.0, 3000.0), 0)
	var strong_ai := AIDirector.new(1)
	strong_ai.tick(strong, AIDirector.STRATEGY_INTERVAL + 0.01)
	_info("  强方战略 = %s" % strong_ai.current_strategy())
	_expect(strong_ai.current_strategy() == "aggressive",
		"压倒性优势 → aggressive（实际 %s）" % strong_ai.current_strategy())
	strong.shutdown()

	# 弱：一艘小飞机打三艘重巡
	var weak := _new_session()
	weak.spawn_unit("light", Vector3(0.0, 0.0, 0.0), 1)
	for i in 3:
		weak.spawn_unit("heavy", Vector3(float(i) * 300.0, 0.0, 3000.0), 0)
	var weak_ai := AIDirector.new(1)
	weak_ai.tick(weak, AIDirector.STRATEGY_INTERVAL + 0.01)
	_info("  弱方战略 = %s" % weak_ai.current_strategy())
	_expect(weak_ai.current_strategy() == "defensive",
		"明显劣势 → defensive（实际 %s）" % weak_ai.current_strategy())
	weak.shutdown()


# ---------------------------------------------------------------- 工具

func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


func _header(text: String) -> void:
	print("[verify_aidir] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_aidir] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_aidir]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_aidir]   FAIL  %s" % what)


func _report() -> void:
	print("[verify_aidir] ---- 结果 ----")
	print("[verify_aidir]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_aidir] PASS")
		get_tree().quit(0)
	else:
		print("[verify_aidir] FAIL")
		get_tree().quit(1)
