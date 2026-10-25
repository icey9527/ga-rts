extends Node3D

## T-4.1 验收：全部机型都能生成并参战。
##
## 数据表写对了不等于能跑：UnitDef 缺键会拒绝生成、武器表缺键会让炮塔组为空、
## 半径给错会让寻路与命中失效。本场景把**全部 17 个机型**（15 新 + 2 现役）
## 摆上场打一场，任何一艘生成失败或永远不开火都会被断言抓住。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_roster.tscn

const DT := 1.0 / 60.0
const SEPARATION := 400.0
const MAX_TICKS := 5400

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_roster] ==== 全机型生成与参战 ====")

	var reg := GameState.registry()
	var ids := reg.units()
	_info("注册表机型 %d 个" % ids.size())
	_expect(ids.size() >= 17, "机型数量 ≥ 17（实际 %d）" % ids.size())

	var session := BattleSession.new()
	session.setup(reg, CommandBus)

	var spawned: Array[Unit] = []
	var failed: Array[String] = []
	for i in ids.size():
		var def_id := ids[i]
		var z := float(i) * SEPARATION
		var a := session.spawn_unit(def_id, Vector3(-800.0, 0.0, z), 0)
		var b := session.spawn_unit(def_id, Vector3(800.0, 0.0, z), 1)
		if a == null or b == null:
			failed.append(def_id)
		else:
			spawned.append(a)
			spawned.append(b)

	_expect(failed.is_empty(), "全部机型生成成功（失败：%s）" % str(failed))
	_expect(session.unit_count() == ids.size() * 2,
		"场上单位数 = 机型数 × 2（实际 %d）" % session.unit_count())

	# 每个机型都必须有炮塔，否则永远不会开火（_step_weapons 直接跳过）
	var no_weapon := 0
	for unit in session.units():
		if unit.weapons == null or unit.weapons.mount_count() == 0:
			no_weapon += 1
			_info("  !! %s 没有炮塔" % unit.def_id)
	_expect(no_weapon == 0, "所有单位都有炮塔（无炮塔 %d 个）" % no_weapon)

	# 半径必须与模型量级匹配（0 或异常大都是数据错误）
	var bad_radius := 0
	for unit in session.units():
		if unit.radius <= 0.1 or unit.radius > 1200.0:
			bad_radius += 1
			_info("  !! %s radius=%.2f" % [unit.def_id, unit.radius])
	_expect(bad_radius == 0, "半径都在合理区间（异常 %d 个）" % bad_radius)

	var ai := SimpleAI.new(1)
	var ticks := 0
	while ticks < MAX_TICKS and not session.is_battle_over():
		ai.tick(session, DT)
		session.tick(DT)
		ticks += 1

	var st := session.stats()
	_info("  %d tick（%.1f 秒）：弹体 %d 发 / 命中 %d / 死亡 %d / 存活 %d" % [
		ticks, float(ticks) * DT, int(st["shots_spawned"]), int(st["hits_applied"]),
		int(st["deaths_settled"]), session.unit_count()])
	_expect(int(st["shots_spawned"]) > 0, "全机种混战确实开火（%d 发）" % int(st["shots_spawned"]))
	_expect(int(st["hits_applied"]) > 0, "确实命中（%d 次）" % int(st["hits_applied"]))
	_expect(int(st["deaths_settled"]) > 0, "确实有单位被击毁（%d 个）" % int(st["deaths_settled"]))

	session.shutdown()

	print("[verify_roster] ---- 结果 ----")
	print("[verify_roster]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_roster] PASS")
		get_tree().quit(0)
	else:
		print("[verify_roster] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_roster] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_roster]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_roster]   FAIL  %s" % what)
