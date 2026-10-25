extends Node3D

## T-2.4 验收：死亡清理与请求-结算两段式（ADR-0012 机制 #4）。
##
## 要证明的核心命题不是"能删掉单位"，而是**删除这件事的时机和次数是确定的**：
##   · 本 tick 产生的生成/销毁只入队，第 8 步才结算（第 1~7 步集合恒定）
##   · unit_died 只发一次，且发在集合已变更之后（监听者看到的状态自洽）
##   · 击杀归属能追溯到发射者
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_death.tscn

const DT := 1.0 / 60.0
## 机型逻辑 ID（= content/units 下的目录名）
const SHIP := "ou05"
const TEAM_BLUE := 0
const TEAM_RED := 1

## 弹体路径用例：把目标血改到 1 点，任何命中都致死，避免依赖武器的转向/冷却
const VICTIM_SPAWN := Vector3(0.0, 0.0, -300.0)
const PROJECTILE_SPEED := 2000.0

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_death] ==== T-2.4 死亡清理与请求-结算 ====")
	_case_1_request_deferred()
	_case_2_settle_once()
	_case_3_signal_after_removal()
	_case_4_idempotent()
	_case_5_fallback_sweep()
	_case_6_squad_target_cleared()
	_case_7_squad_dropped()
	_case_8_deterministic_order()
	_case_9_projectile_attribution()

	print("[verify_death] ---- 结果 ----")
	print("[verify_death]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_death] PASS")
		get_tree().quit(0)
	else:
		print("[verify_death] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例

## 1. 生成请求不当场生效：request_spawn 只入队，下一 tick 第 8 步才真生成
func _case_1_request_deferred() -> void:
	_header("1. request_spawn 只入队，不当场生效")
	var s := _new_session()
	var first := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	_expect(first != null, "常规 spawn_unit 立即生成")
	_expect(s.unit_count() == 1, "unit_count = 1")

	s.request_spawn(SHIP, Vector3(500.0, 0.0, 0.0), TEAM_RED)
	_expect(s.unit_count() == 1, "request_spawn 之后 unit_count 仍是 1（未结算）")
	_expect(s.spawn_request_count() == 1, "请求表里排着 1 条")

	s.tick(DT)
	_expect(s.unit_count() == 2, "tick 结算后 unit_count = 2")
	_expect(s.spawn_request_count() == 0, "请求表已清空")
	_expect(int(s.stats()["spawns_settled"]) == 1, "spawns_settled 累计 1")
	s.shutdown()


## 2. 致死伤害 → 结算后移除；同一单位的死亡只结算一次
func _case_2_settle_once() -> void:
	_header("2. 死亡结算：两段式 + 只结算一次")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	_expect(s.unit_count() == 2, "开局两艘")

	var died_count := [0]
	var killer_seen := [-99]
	s.unit_died.connect(func(u: Unit, k: int) -> void:
		died_count[0] += 1
		killer_seen[0] = k)

	var lethal := victim.apply_damage(1.0e9)
	_expect(lethal, "致死伤害返回 true（目标侧已判定死亡）")
	_expect(not victim.alive, "victim.alive 已为 false")
	_expect(s.unit_count() == 2, "**结算前 unit_count 仍是 2** —— 销毁没有当场生效")

	s.request_kill(victim.id, killer.id)
	_expect(s.kill_request_count() == 1, "销毁请求入队 1 条")
	_expect(s.unit_count() == 2, "request_kill 之后 unit_count 仍是 2")

	s.tick(DT)
	_expect(s.unit_count() == 1, "tick 结算后 unit_count = 1")
	_expect(died_count[0] == 1, "unit_died 只发了 1 次（实际 %d）" % died_count[0])
	_expect(killer_seen[0] == killer.id, "击杀归属正确（killer_id=%d，期望 %d）" % [
		killer_seen[0], killer.id])
	_expect(int(s.stats()["deaths_settled"]) == 1, "deaths_settled 累计 1")
	_expect(s.kill_request_count() == 0, "销毁请求表已清空")
	s.shutdown()


## 3. 信号发射时机：发在集合变更**之后**，监听者看到的 session 已自洽
func _case_3_signal_after_removal() -> void:
	_header("3. unit_died 发在移除之后（监听者看到自洽状态）")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)

	var inside := {"count": -1, "still_registered": true, "alive_flags": -1}
	var victim_id := victim.id
	s.unit_died.connect(func(u: Unit, _k: int) -> void:
		inside["count"] = s.unit_count()
		var found := false
		for other in s.units():
			if other.id == victim_id:
				found = true
		inside["still_registered"] = found
		var dead_left := 0
		for other in s.units():
			if not other.alive:
				dead_left += 1
		inside["alive_flags"] = dead_left)

	victim.apply_damage(1.0e9)
	s.request_kill(victim.id, killer.id)
	s.tick(DT)

	_expect(inside["count"] == 1, "回调里 unit_count 已经是 1（不是 2）")
	_expect(inside["still_registered"] == false, "回调里已经查不到死者")
	_expect(inside["alive_flags"] == 0, "回调里 units() 中没有任何 alive=false 的残留")
	s.shutdown()


## 4. 幂等：同一 id 重复请求不会重复结算、不会重复发信号
func _case_4_idempotent() -> void:
	_header("4. 重复请求幂等")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	var died_count := [0]
	s.unit_died.connect(func(_u: Unit, _k: int) -> void: died_count[0] += 1)

	victim.apply_damage(1.0e9)
	s.request_kill(victim.id, killer.id)
	s.request_kill(victim.id, killer.id)
	s.request_kill(victim.id, -1)
	_expect(s.kill_request_count() == 1, "三次重复请求合并成 1 条")
	s.tick(DT)
	_expect(died_count[0] == 1, "unit_died 仍只发 1 次")
	_expect(int(s.stats()["deaths_settled"]) == 1, "deaths_settled 仍是 1")

	# 死人再请求一次：不该再发信号（它已经不在 _units 里）
	s.request_kill(victim.id, killer.id)
	s.tick(DT)
	_expect(died_count[0] == 1, "对已移除单位再请求不重复发信号")
	s.shutdown()


## 5. 兜底：外部直接置 alive=false（没走请求表）也要被清掉，killer 记 -1
func _case_5_fallback_sweep() -> void:
	_header("5. 兜底扫描：绕过请求表直接置死也能清理")
	var s := _new_session()
	s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	var killer_seen := [-99]
	s.unit_died.connect(func(_u: Unit, k: int) -> void: killer_seen[0] = k)

	# 刻意不调 request_kill，直接置死（模拟剧本杀 / 外部逻辑）
	victim.alive = false
	_expect(s.unit_count() == 2, "置死后、tick 前仍是 2")
	s.tick(DT)
	_expect(s.unit_count() == 1, "兜底扫描把它清掉了")
	_expect(killer_seen[0] == -1, "无归属时 killer_id = -1（实际 %d）" % killer_seen[0])
	s.shutdown()


## 6. 索敌目标已死 → 编队的目标归位
func _case_6_squad_target_cleared() -> void:
	_header("6. 索敌目标死亡 → squad.target_id 归位")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)

	var squads := s.squads()
	_expect(squads.size() == 2, "两个队各一个编队（实际 %d）" % squads.size())
	var blue_squad: Squad = squads[0] if squads[0].team == TEAM_BLUE else squads[1]
	blue_squad.target_id = victim.id
	_expect(blue_squad.has_target(), "先把目标指到敌方")

	victim.apply_damage(1.0e9)
	s.request_kill(victim.id, killer.id)
	s.tick(DT)
	_expect(not blue_squad.has_target(),
		"目标死后 squad.target_id 归位（当前 %d）" % blue_squad.target_id)
	_expect(blue_squad.target_id == Squad.NO_TARGET, "归位到 NO_TARGET")
	s.shutdown()


## 7. 全员阵亡的编队直接丢弃
func _case_7_squad_dropped() -> void:
	_header("7. 空编队丢弃")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var r1 := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	var r2 := s.spawn_unit(SHIP, VICTIM_SPAWN + Vector3(100.0, 0.0, 0.0), TEAM_RED)
	_expect(s.squad_count() == 2, "开局两个编队")

	r1.apply_damage(1.0e9)
	r2.apply_damage(1.0e9)
	s.request_kill(r1.id, killer.id)
	s.request_kill(r2.id, killer.id)
	s.tick(DT)

	_expect(s.unit_count() == 1, "红队全灭，只剩 1 艘")
	_expect(s.squad_count() == 1, "红队编队被丢弃，只剩 1 个（实际 %d）" % s.squad_count())
	_expect(s.squads()[0].team == TEAM_BLUE, "留下的是蓝队编队")
	s.shutdown()


## 8. 同一 tick 多单位死亡：信号按 id 升序，顺序确定
func _case_8_deterministic_order() -> void:
	_header("8. 同 tick 多死的通知顺序确定（id 升序）")
	var s := _new_session()
	var killer := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var a := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	var b := s.spawn_unit(SHIP, VICTIM_SPAWN + Vector3(100.0, 0.0, 0.0), TEAM_RED)

	var order: Array[int] = []
	s.unit_died.connect(func(u: Unit, _k: int) -> void: order.append(u.id))

	a.apply_damage(1.0e9)
	b.apply_damage(1.0e9)
	# 故意反序入队，检验结算端自己排序
	s.request_kill(b.id, killer.id)
	s.request_kill(a.id, killer.id)
	s.tick(DT)

	_expect(order.size() == 2, "两次死亡通知（实际 %d）" % order.size())
	if order.size() == 2:
		_expect(order[0] == a.id and order[1] == b.id,
			"按 id 升序通知（实际 [%d, %d]，期望 [%d, %d]）" % [
				order[0], order[1], a.id, b.id])
	s.shutdown()


## 9. 走真弹体路径：击杀归属能追溯到发射者
func _case_9_projectile_attribution() -> void:
	_header("9. 弹体击杀 → killer_id = 发射者")
	var s := _new_session()
	var shooter := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var victim := s.spawn_unit(SHIP, VICTIM_SPAWN, TEAM_RED)
	# 血改到 1 点：任何命中都致死，不必等武器转向与冷却
	victim.hp = 1.0
	victim.max_hp = 1.0

	var killer_seen := [-99]
	var died_count := [0]
	s.unit_died.connect(func(_u: Unit, k: int) -> void:
		died_count[0] += 1
		killer_seen[0] = k)

	# 手动造一发高速弹，朝目标直飞
	var dir := (victim.position - shooter.position).normalized()
	s.projectiles().spawn(shooter.position, dir, PROJECTILE_SPEED, 500.0,
		shooter.team, shooter.id, 0.8, 4.0)

	var ticks := 0
	while ticks < 60 and victim.alive:
		s.tick(DT)
		ticks += 1

	_info("  飞行 %d tick 后命中（%.2f 秒）" % [ticks, float(ticks) * DT])
	_expect(not victim.alive, "目标被弹体击杀")
	_expect(died_count[0] == 1, "unit_died 发 1 次")
	_expect(killer_seen[0] == shooter.id,
		"杀手追溯到发射者（killer_id=%d，期望 %d）" % [killer_seen[0], shooter.id])
	_expect(s.unit_count() == 1, "只剩发射者")
	_expect(int(s.stats()["hits_applied"]) >= 1, "命中计数已累加")
	s.shutdown()


# ---------------------------------------------------------------- 场景构造

func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


# ---------------------------------------------------------------- 输出

func _header(text: String) -> void:
	print("[verify_death] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_death] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_death]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_death]   FAIL  %s" % what)
