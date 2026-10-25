extends Node3D

## 可玩性验收：**玩家一枪不放，主场景里的两支舰队能不能自己打起来**。
##
## 这一条不是为了测 AI 有多聪明，而是回归一个真实事故：
## S3 结束时打开主场景，能选中、能下令、代码零报错，但**永远不打**。三个原因叠在一起：
##   1. skirmish 地图四个 spawn 全写 team=1 —— 场上没有敌人
##   2. Unit 没有 is_hostile()，右键点敌人只会发"移动"命令
##   3. session 没有 cmd_attack 分支，攻击命令被静默忽略；而且根本没有 AI
##
## 本场景用**真地图 + 真 AI + 零玩家输入**跑一遍，证明上面三条都不再成立。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_playable.tscn

const DT := 1.0 / 60.0
const MAP_ID := "skirmish"
const AI_TEAM := 1
## 120 秒模拟时间上限。2v2（重巡 + 突击舰）参照 verify_battle 的收敛速度足够
const MAX_TICKS := 7200
const REPORT_EVERY := 600

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_play] ==== 可玩性：零输入自动开战 ====")
	var session := _build_from_map()
	_expect(session != null, "从 skirmish 地图装配出会话")
	if session == null:
		_report()
		return

	var units := session.units()
	var blue := session.alive_count(0)
	var red := session.alive_count(1)
	_info("  装配：单位 %d（team0=%d，team1=%d），障碍 %d，层级 L%d" % [
		units.size(), blue, red, session.obstacle_count(), session.layer_index()])
	_expect(units.size() == 4, "地图里的 4 个 spawn 全部生成（实际 %d）" % units.size())
	_expect(blue >= 1 and red >= 1,
		"**两支队伍都有单位**（team0=%d，team1=%d）" % [blue, red])

	# AI 只驱动 team 1；玩家（team 0）全程不下任何命令
	var ai := SimpleAI.new(AI_TEAM)
	var ticks := 0
	while ticks < MAX_TICKS and not session.is_battle_over():
		ai.tick(session, DT)
		session.tick(DT)
		ticks += 1
		if ticks % REPORT_EVERY == 0:
			_info("  [%5.1f s] team0=%d team1=%d 弹体=%d 命中=%d 死亡=%d" % [
				float(ticks) * DT, session.alive_count(0), session.alive_count(1),
				session.projectiles().active_count(),
				int(session.stats()["hits_applied"]),
				int(session.stats()["deaths_settled"])])

	var st := session.stats()
	_info("  结果：%d tick（%.1f 秒），winner=%d，team0=%d team1=%d" % [
		ticks, float(ticks) * DT, session.winner(),
		session.alive_count(0), session.alive_count(1)])
	_info("  统计：AI 下令 %d 次，弹体 %d 发，命中 %d，死亡 %d" % [
		ai.orders_issued(), int(st["shots_spawned"]), int(st["hits_applied"]),
		int(st["deaths_settled"])])

	_expect(ai.orders_issued() > 0, "AI 下达过攻击命令（%d 次）" % ai.orders_issued())
	_expect(int(st["shots_spawned"]) > 0, "**真的开火了**（弹体 %d 发）" % int(st["shots_spawned"]))
	_expect(int(st["hits_applied"]) > 0, "**真的命中了**（%d 次）" % int(st["hits_applied"]))
	_expect(int(st["deaths_settled"]) > 0,
		"**真的有单位被打掉**（死亡 %d）—— 这就是之前“没打起来”的判据" % int(st["deaths_settled"]))
	_expect(session.winner() != BattleSession.NO_WINNER,
		"在 %.0f 秒内分出胜负（winner=%d）" % [MAX_TICKS * DT, session.winner()])

	session.shutdown()
	_report()


func _report() -> void:
	print("[verify_play] ---- 结果 ----")
	print("[verify_play]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_play] PASS")
		get_tree().quit(0)
	else:
		print("[verify_play] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 装配（照 battle.gd 的口径）

func _build_from_map() -> BattleSession:
	var reg := GameState.registry()
	if reg == null:
		_expect(false, "Registry 不可用")
		return null
	var record := reg.map(MAP_ID)
	if record.is_empty():
		_expect(false, "地图 '%s' 读取失败" % MAP_ID)
		return null
	var map := MapDef.from_record(MAP_ID, record, reg)
	if not map.is_valid():
		_expect(false, "地图 '%s' 数据不合法（%d 处错误）" % [MAP_ID, map.errors.size()])
		return null

	var session := BattleSession.new()
	session.setup(reg, CommandBus)
	session.set_layer_height(MapDef.layer_center(map.layer_default))

	for entry in map.obstacles:
		var obstacle := NavObstacle.new()
		obstacle.setup(entry.position, entry.radius, entry.top_y, entry.bottom_y)
		session.add_obstacle(obstacle)

	for entry in map.spawns:
		session.spawn_unit(entry.unit_id, entry.position, entry.team)

	return session


func _info(text: String) -> void:
	print("[verify_play] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_play]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_play]   FAIL  %s" % what)
