extends Node3D

## 回归：单位阵亡后**表现层模型必须消失**。
##
## 事故：模拟层早就在 _settle_kills 里正常销毁单位并发 unit_died，
## 但 battle.gd 只接了 unit_spawned / route_assigned / command_applied，
## **没接 unit_died** → UnitView 没人释放 → 被打死的敌模型一直留在场上。
##
## 本场景用真实 battle.tscn 跑一遍：杀掉一艘，等几个 tick，
## 断言 ① 模拟层少一艘 ② 表现层也少一个 ③ unit_view() 查不到死者。

const BATTLE := "res://scenes/battle/battle.tscn"

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_dv] ==== 阵亡后模型释放 ====")

	var packed := load(BATTLE) as PackedScene
	if packed == null:
		_expect(false, "加载 battle.tscn")
		_report()
		return
	var battle := packed.instantiate()
	add_child(battle)
	for i in 5:
		await get_tree().process_frame

	var session: BattleSession = battle.session()
	_expect(session != null, "拿到会话")
	if session == null:
		_report()
		return

	var before := _count_views(battle)
	_info("开局：单位 %d 艘，UnitView %d 个" % [session.unit_count(), before])
	_expect(before == session.unit_count(),
		"视图数与单位数一致（%d vs %d）" % [before, session.unit_count()])
	_expect(before >= 2, "场上至少 2 艘（实际 %d）" % before)
	if before < 2:
		_report()
		return

	# 杀第一艘
	var victim: Unit = session.units()[0]
	var victim_id := victim.id
	var victim_def := victim.def_id
	victim.apply_damage(1.0e9)
	session.request_kill(victim_id, -1)

	# 等 Simulation（autoload 每帧驱动）推进几步，让第 8 步结算
	for i in 20:
		await get_tree().process_frame

	var after := _count_views(battle)
	_info("杀掉 #%d（%s）后：单位 %d 艘，UnitView %d 个" % [
		victim_id, victim_def, session.unit_count(), after])

	_expect(session.unit_count() == before - 1,
		"模拟层少了 1 艘（%d → %d）" % [before, session.unit_count()])
	_expect(after == before - 1,
		"**表现层也少了 1 个 UnitView**（%d → %d）—— 这是之前漏掉的那条接线" % [before, after])
	_expect(battle.unit_view(victim_id) == null,
		"unit_view() 已经查不到死者 #%d" % victim_id)

	# 其余单位的视图仍应健在
	_expect(_count_views(battle) == session.unit_count(),
		"剩余单位的视图数量仍与模拟层一致")

	_report()


func _report() -> void:
	print("[verify_dv] ---- 结果 ----")
	print("[verify_dv]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_dv] PASS")
		get_tree().quit(0)
	else:
		print("[verify_dv] FAIL")
		get_tree().quit(1)


func _count_views(node: Node) -> int:
	var total := 0
	for child in node.get_children():
		if child is UnitView:
			total += 1
		total += _count_views(child)
	return total


func _info(text: String) -> void:
	print("[verify_dv] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_dv]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_dv]   FAIL  %s" % what)
