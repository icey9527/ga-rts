extends Node3D

## T-2.5 验收：两军各 5 单位对战（S2 收尾卡）。
##
## 这一卡与前四张的验证性质不同：前面都是**单系统**验收（寻路/状态机/炮塔/弹体/死亡），
## 这里验的是**九步 tick 在全负载下还能不能自洽** ——
## 5v5 混编 + 多目标 + 弹体并发 + 死亡连锁 + 胜负判定同时发生。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_battle.tscn
##
## 本场景**刻意不带障碍**：障碍的绕行已在 verify_nav（39 断言）与 verify_slice（48 断言）
## 验证过，这里只验战斗能否收敛。混进来的话"单位卡在岩石后面"会伪装成"战斗打不完"，
## 让失败原因变得不可判读。

const DT := 1.0 / 60.0
const TEAM_BLUE := 0
const TEAM_RED := 1

## 机型逻辑 ID（= content/units 下的目录名）
const CRUISER := "ou134"
const FRIGATE := "ou05"

## 每队 5 艘：1 重巡（血量 12800 / 重炮 2000 m）+ 4 突击舰（血量 4200 / 脉冲炮 700 m）
const PER_SIDE := 5

## 两军相距 1800 m：重炮（2000 m）开场即可开火，突击舰（700 m）必须压上 —— 两种行为都能跑到
const BLUE_ANCHOR_Z := -900.0
const RED_ANCHOR_Z := 900.0

## 单场模拟时长上限：240 秒。按 DPS 估算（蓝方合计约 1965 DPS / 红方 29600 血）
## 理论 15 秒清空，留 16 倍余量吸收转向、冷却、飞行时间
const MAX_TICKS := 14400
## 进度打印间隔（每 10 秒模拟时间一行）
const REPORT_EVERY := 600

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_battle] ==== T-2.5 两军各 5 单位对战 ====")

	var first := _run_battle(0)
	_report_battle(first, "第一场")

	_case_1_setup(first)
	_case_2_resolution(first)
	_case_3_casualties(first)
	_case_4_engagement(first)

	var second := _run_battle(1)
	_case_5_determinism(first, second)

	print("[verify_battle] ---- 结果 ----")
	print("[verify_battle]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_battle] PASS")
		get_tree().quit(0)
	else:
		print("[verify_battle] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例

## 1. 双方各 5 艘都生成成功
func _case_1_setup(r: Dictionary) -> void:
	_header("1. 双方各 %d 艘成功生成" % PER_SIDE)
	_expect(int(r["spawned_blue"]) == PER_SIDE,
		"蓝方生成 %d 艘（期望 %d）" % [int(r["spawned_blue"]), PER_SIDE])
	_expect(int(r["spawned_red"]) == PER_SIDE,
		"红方生成 %d 艘（期望 %d）" % [int(r["spawned_red"]), PER_SIDE])
	_expect(int(r["start_blue"]) == PER_SIDE and int(r["start_red"]) == PER_SIDE,
		"开局双方各 %d 艘存活" % PER_SIDE)


## 2. 战斗在时限内分出胜负
func _case_2_resolution(r: Dictionary) -> void:
	_header("2. 战斗收敛并分出胜负（上限 %d tick = %.0f 秒）" % [MAX_TICKS, MAX_TICKS * DT])
	var winner := int(r["winner"])
	_expect(winner != BattleSession.NO_WINNER,
		"在 %d tick 内分出了结果（winner=%d）" % [int(r["ticks"]), winner])
	_expect(winner == TEAM_BLUE or winner == TEAM_RED,
		"赢家是一个具体队伍（%s）" % ("蓝方" if winner == TEAM_BLUE else
			("红方" if winner == TEAM_RED else "无（%d）" % winner)))
	_expect(int(r["ticks"]) < MAX_TICKS,
		"没有跑到时限才停（实际 %d tick）" % int(r["ticks"]))
	if int(r["ticks"]) > 0:
		_info("  会战时长 %.1f 秒（%d tick）" % [float(r["ticks"]) * DT, int(r["ticks"])])


## 3. 伤亡：败方清零、胜方留人、死亡计数自洽
func _case_3_casualties(r: Dictionary) -> void:
	_header("3. 伤亡与结算一致性")
	var winner := int(r["winner"])
	var blue_left := int(r["blue_left"])
	var red_left := int(r["red_left"])
	var deaths := int(r["deaths"])

	var loser_left := red_left if winner == TEAM_BLUE else blue_left
	var winner_left := blue_left if winner == TEAM_BLUE else red_left

	_expect(loser_left == 0, "败方全灭（剩 %d）" % loser_left)
	_expect(winner_left > 0, "胜方还有 %d 艘存活" % winner_left)
	_expect(winner_left <= PER_SIDE, "胜方存活数不超过初始规模（%d ≤ %d）" % [winner_left, PER_SIDE])
	_expect(deaths == PER_SIDE * 2 - blue_left - red_left,
		"deaths_settled 与场上存活数自洽（死亡 %d = %d×2 - %d - %d）" % [
			deaths, PER_SIDE, blue_left, red_left])
	_expect(deaths >= PER_SIDE,
		"至少一方被打光（死亡 %d ≥ %d）" % [deaths, PER_SIDE])


## 4. 真的打了：有弹体、有命中、单位动过
func _case_4_engagement(r: Dictionary) -> void:
	_header("4. 确实发生了交战（不是原地判定胜利）")
	_expect(int(r["shots"]) > 0, "总共发射 %d 发弹体" % int(r["shots"]))
	_expect(int(r["hits"]) > 0, "总共命中 %d 次" % int(r["hits"]))
	_expect(int(r["moved"]) > 0,
		"%d 艘单位移动到过新位置（航线/追击生效）" % int(r["moved"]))
	_expect(int(r["hits"]) <= int(r["shots"]),
		"命中数不超过发射数（%d ≤ %d）" % [int(r["hits"]), int(r["shots"])])


## 5. 确定性：同输入两次跑出同样的胜负与结束时刻
func _case_5_determinism(a: Dictionary, b: Dictionary) -> void:
	_header("5. 确定性（两场结果逐项比对）")
	_expect(int(a["winner"]) == int(b["winner"]),
		"胜者相同（%d vs %d）" % [int(a["winner"]), int(b["winner"])])
	_expect(int(a["ticks"]) == int(b["ticks"]),
		"结束 tick 相同（%d vs %d）" % [int(a["ticks"]), int(b["ticks"])])
	_expect(int(a["blue_left"]) == int(b["blue_left"]) and int(a["red_left"]) == int(b["red_left"]),
		"最终存活数相同（蓝 %d/%d，红 %d/%d）" % [
			int(a["blue_left"]), int(b["blue_left"]), int(a["red_left"]), int(b["red_left"])])
	_expect(int(a["deaths"]) == int(b["deaths"]),
		"死亡数相同（%d vs %d）" % [int(a["deaths"]), int(b["deaths"])])
	_expect(int(a["hits"]) == int(b["hits"]),
		"命中数相同（%d vs %d）" % [int(a["hits"]), int(b["hits"])])


# ---------------------------------------------------------------- 会战

## 跑一场 5v5。返回结果字典（不含任何 Node 引用，便于跨场比对）。
func _run_battle(seed_id: int) -> Dictionary:
	var session := _new_session()

	var blue_positions := _formation(BLUE_ANCHOR_Z)
	var red_positions := _formation(RED_ANCHOR_Z)

	var blue: Array[Unit] = []
	var red: Array[Unit] = []
	for i in blue_positions.size():
		var def_id := CRUISER if i == 0 else FRIGATE
		var u := session.spawn_unit(def_id, blue_positions[i], TEAM_BLUE)
		if u != null:
			blue.append(u)
	for i in red_positions.size():
		var def_id := CRUISER if i == 0 else FRIGATE
		var u := session.spawn_unit(def_id, red_positions[i], TEAM_RED)
		if u != null:
			red.append(u)

	var start_positions := {}
	for u in blue:
		start_positions[u.id] = u.position
	for u in red:
		start_positions[u.id] = u.position
	# 开局实测存活数（不要写成常量，否则“开局 5 艘”就成了恒真断言）
	var start_blue := session.alive_count(TEAM_BLUE)
	var start_red := session.alive_count(TEAM_RED)

	# 双方互相突击到对方重心：不给这条命令，两边会原地不动，永远打不起来
	CommandBus.issue(blue, BattleSession.CMD_ATTACK_MOVE,
		{"point": _centroid(red), "source": &"verify_battle"})
	CommandBus.issue(red, BattleSession.CMD_ATTACK_MOVE,
		{"point": _centroid(blue), "source": &"verify_battle"})

	var ticks := 0
	while ticks < MAX_TICKS and not session.is_battle_over():
		session.tick(DT)
		ticks += 1
		if ticks % REPORT_EVERY == 0:
			_info("  [%4.1f s] 蓝 %d / 红 %d，弹体在飞 %d，累计命中 %d" % [
				float(ticks) * DT, session.alive_count(TEAM_BLUE),
				session.alive_count(TEAM_RED),
				session.projectiles().active_count(),
				int(session.stats()["hits_applied"])])

	# 「动过」的判定：位置偏离出生点超过 1 m
	var moved := 0
	for u in session.units():
		if start_positions.has(u.id):
			if (u.position as Vector3).distance_to(start_positions[u.id]) > 1.0:
				moved += 1

	var stats := session.stats()
	# 卡死诊断：打不出胜负时把每个幸存者的真实状态打印出来，
	# 否则“没打死”和“根本没在打”从外部看起来一模一样。
	if session.winner() == BattleSession.NO_WINNER:
		_dump_stall(session)
	var result := {
		"seed": seed_id,
		"winner": session.winner(),
		"ticks": ticks,
		"blue_left": session.alive_count(TEAM_BLUE),
		"red_left": session.alive_count(TEAM_RED),
		"spawned_blue": blue.size(),
		"spawned_red": red.size(),
		"start_blue": start_blue,
		"start_red": start_red,
		"deaths": int(stats["deaths_settled"]),
		"shots": int(stats["shots_spawned"]),
		"hits": int(stats["hits_applied"]),
		"moved": moved,
	}
	session.shutdown()
	return result


## 卡死时打印每个存活单位的战术状态。
func _dump_stall(session: BattleSession) -> void:
	_info("  卡死诊断（存活单位逐个）：")
	for u in session.units():
		if not u.alive:
			continue
		var tgt := session.context().unit_by_id(u.target_id)
		var dist := -1.0
		var tgt_team := -99
		if tgt != null:
			dist = u.position.distance_to(tgt.position)
			tgt_team = tgt.team
		_info("    #%d %s team=%d state=%s target=%d(team %d, %.0f m) 射程内=%s pos=(%.0f, %.0f, %.0f)" % [
			u.id, u.def_id, u.team, UnitStates.state_name(u.state), u.target_id, tgt_team,
			dist, str(dist >= 0.0 and dist <= u.weapon_range),
			u.position.x, u.position.y, u.position.z])
	var st := session.stats()
	_info("    汇总：shots_spawned=%d hits_applied=%d states=%s" % [
		int(st["shots_spawned"]), int(st["hits_applied"]), str(st["states"])])


## 一字横阵：重巡居中压前，4 艘突击舰分列两侧、略靠后。
## 取负 Z 为蓝方前沿（机头默认 -Z），红方镜像。
func _formation(anchor_z: float) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var sign_z := signf(anchor_z)
	out.append(Vector3(0.0, 0.0, anchor_z))
	out.append(Vector3(-600.0, 80.0, anchor_z + sign_z * 200.0))
	out.append(Vector3(-300.0, 80.0, anchor_z + sign_z * 200.0))
	out.append(Vector3(300.0, 80.0, anchor_z + sign_z * 200.0))
	out.append(Vector3(600.0, 80.0, anchor_z + sign_z * 200.0))
	return out


func _centroid(units: Array[Unit]) -> Vector3:
	if units.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for u in units:
		sum += u.position
	return sum / float(units.size())


func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


# ---------------------------------------------------------------- 输出

func _report_battle(r: Dictionary, title: String) -> void:
	var winner := int(r["winner"])
	var who := "蓝方" if winner == TEAM_BLUE else ("红方" if winner == TEAM_RED else
		("同归于尽" if winner == BattleSession.MUTUAL_DESTRUCTION else "无（未决）"))
	_info("%s：%s 胜，%d tick（%.1f 秒），蓝剩 %d / 红剩 %d，死亡 %d，弹体 %d 发 / 命中 %d" % [
		title, who, int(r["ticks"]), float(int(r["ticks"])) * DT,
		int(r["blue_left"]), int(r["red_left"]), int(r["deaths"]),
		int(r["shots"]), int(r["hits"])])


func _header(text: String) -> void:
	print("[verify_battle] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_battle] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_battle]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_battle]   FAIL  %s" % what)
