extends Node3D

## AI 层验证场景（T-2.1：个体状态机 + 编队级集中选靶）。开发期工具，不属于游戏主流程。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path F:\godot\ga-rts \
##         scenes/dev/verify_ai.tscn
##     通过 → exit 0    失败 → exit 1
##
## 六个用例（对应任务卡的验收点，逐条断言）：
##   1. 节流生效：120 tick（2 秒）→ 扫描 2~3 次，绝不是 120 次
##   2. 接近时间排序：3 个敌人**同距离**但接近速度不同 → 选中接近时间最小的
##   3. 咬尾优先：打上 recently_damaged 后，后方敌人优先于前方（且没打标记时是前方的）
##   4. 状态转移：IDLE → MOVING →（进射程）ATTACKING →（目标死亡）IDLE →（航线还在）MOVING
##   5. 目标死亡自动失效：杀掉目标后 squad.target_id / unit.target_id 清空，个体不报错
##   6. 确定性：相同输入跑两遍，目标选择与最终位置逐元素相同
##   附A. 结构约束：AI 层四个类都是 RefCounted，不是 Node；状态机不改 position
##
## 用例 2/3 故意**不经过 BattleSession**：手搓 Unit + Squad + BattleContext 就能测选靶，
## 这正是"AI 不直接摸 Session"（BattleContext 存在的理由）带来的可测性。
## 用例 1/4/5/6 走真会话：要验证的是接线顺序（九步里的位置），不是算法本身。
##
## 坐标与射程口径：1 unit = 1 m（docs/scale-and-units.md），普通武器射程 500 m ~ 2 km，
## 手搓单位一律用 WEAPON_RANGE = 1800 m（= content/units/ou05 的 [weapon] range）。

## 模拟步长（与 Simulation.TICK_RATE = 60 一致）
const DT := 1.0 / 60.0
## 机型逻辑 ID（= content/units 下的目录名，不是路径）
const SHIP_DEF_ID := "ou05"
## 队伍号（0 = 蓝 / 1 = 红；地图表里也是这个约定）
const TEAM_BLUE := 0
const TEAM_RED := 1
## 武器射程（米）：与 content/units/ou05 的 [weapon] range 一致
const WEAPON_RANGE := 1800.0

# ---------------------------------------------------------------- 用例 1 参数
const THROTTLE_TICKS := 120
const THROTTLE_MIN_SCANS := 2
const THROTTLE_MAX_SCANS := 3

# ---------------------------------------------------------------- 用例 2/3 参数
## 手搓单位的巡航速度（m/s），用来构造"相对接近速度"
const MOCK_SPEED := 100.0
## 用例 2：三个敌人的半径（米）—— 完全相同的距离
const ORBIT_RADIUS := 1000.0
## 用例 3：前方的慢追兵与后方的快追兵
const FRONT_DISTANCE := 800.0
const FRONT_CLOSING := 300.0
const BACK_DISTANCE := 900.0
const BACK_CLOSING := 100.0

# ---------------------------------------------------------------- 用例 4/5 参数
## attack_move 的目标点（离起点 6 km，保证用例跑完时航线还没走完）
const MOVE_TARGET := Vector3(0.0, 0.0, -6000.0)
## 敌人的初始位置：距我方 1200 m（射程 1800 内，但索敌要等第一次扫描）
const ENEMY_POSITION := Vector3(0.0, 0.0, -1200.0)
## 等待进入 ATTACKING 的最大 tick 数（扫描 1 s + 余量 → 120 tick 足够）
const ATTACK_WAIT_TICKS := 200

# ---------------------------------------------------------------- 用例 6 参数
const DETERMINISM_TICKS := 300

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	await get_tree().process_frame

	_case_1_throttle()
	_case_2_approach_time_order()
	_case_3_ambush_priority()
	_case_4_state_machine()
	_case_5_target_death()
	_case_6_determinism()
	_case_a_structure()

	_report()


# ---------------------------------------------------------------- 用例 1：节流

func _case_1_throttle() -> void:
	_header("1. 节流 —— %d tick（%.2f s）应只扫 %d~%d 次" % [
		THROTTLE_TICKS, THROTTLE_TICKS * DT, THROTTLE_MIN_SCANS, THROTTLE_MAX_SCANS])
	var session := _new_session()
	var friend := session.spawn_unit(SHIP_DEF_ID, Vector3.ZERO, TEAM_BLUE)
	# 敌人放在索敌范围内（1000 m < 1800 × 1.5）：本用例只看扫描次数，不看选靶结果
	var enemy := session.spawn_unit(SHIP_DEF_ID, Vector3(0.0, 0.0, -1000.0), TEAM_RED)
	if friend == null or enemy == null:
		_expect(false, "spawn_unit 成功（蓝/红各一艘）")
		session.shutdown()
		return

	for i in THROTTLE_TICKS:
		session.tick(DT)

	var stats := session.targeting_stats()
	var scans := int(stats["scans"])
	var tick_based := THROTTLE_TICKS  # 若每帧扫描，这个用例会看到 120
	_info("会话 tick = %d，Targeting.stats = %s" % [session.tick_index(), str(stats)])
	_info("每秒扫描次数 = %.2f（间隔 %.1f s）" % [
		float(scans) / (float(THROTTLE_TICKS) * DT), float(stats["interval"])])

	_expect(scans >= THROTTLE_MIN_SCANS and scans <= THROTTLE_MAX_SCANS,
		"扫描 %d 次落在 [%d, %d]" % [scans, THROTTLE_MIN_SCANS, THROTTLE_MAX_SCANS])
	_expect(scans < tick_based,
		"扫描 %d 次 < tick 数 %d（不是每帧扫）" % [scans, tick_based])
	_expect(float(stats["elapsed"]) < float(stats["interval"]),
		"残余累积 %.4f s < 间隔 %.1f s（节流器把余数留到下轮）" % [
			float(stats["elapsed"]), float(stats["interval"])])
	# 每轮扫描都该看到 2 个敌人 × 1 个编队 → 候选数 = scans × 1（只有红队编队在看蓝队）
	_expect(int(stats["candidates"]) > 0, "确实参与了排序（候选累计 %d）" % int(stats["candidates"]))
	session.shutdown()


# ---------------------------------------------------------------- 用例 2：接近时间排序

func _case_2_approach_time_order() -> void:
	_header("2. 接近时间排序 —— 3 个敌人同距离（%.0f m）、接近速度不同" % ORBIT_RADIUS)
	# 我方：原点朝 -Z 飞 100 m/s
	var friend := _make_unit(1, TEAM_BLUE, Vector3.ZERO, Vector3.FORWARD, MOCK_SPEED)
	# E1：正前方 1000 m，迎着我来 300 m/s
	var e1 := _make_unit(2, TEAM_RED, Vector3(0.0, 0.0, -ORBIT_RADIUS), Vector3(0.0, 0.0, 1.0), 300.0)
	# E2：正后方 1000 m，追着我 150 m/s（我的机头背对它 → 相对接近速度低）
	var e2 := _make_unit(3, TEAM_RED, Vector3(0.0, 0.0, ORBIT_RADIUS), Vector3(0.0, 0.0, -1.0), 150.0)
	# E3：右侧 1000 m，横穿（接近速度 ≈ 0 甚至为负 → 接近时间极大）
	var e3 := _make_unit(4, TEAM_RED, Vector3(ORBIT_RADIUS, 0.0, 0.0), Vector3(-1.0, 0.0, 0.0), 150.0)

	var friendlies: Array[Unit] = [friend]
	var enemies: Array[Unit] = [e1, e2, e3]
	var result := _select_target(friendlies, enemies)
	var squad: Squad = result["squad"]

	for enemy in enemies:
		var dist := friend.position.distance_to(enemy.position)
		_info("  候选 id=%d（%s）距离 = %.3f m，相对接近速度 = %+8.3f m/s，接近时间 = %.6f s" % [
			enemy.id, _side_text(enemy, friend), dist,
			Targeting.closing_speed(friend, enemy), Targeting.approach_time(friend, enemy)])

	var t1 := Targeting.approach_time(friend, e1)
	var t2 := Targeting.approach_time(friend, e2)
	var t3 := Targeting.approach_time(friend, e3)
	_info("选中的目标 id = %d（期望 %d = 最快接近的那个）" % [squad.target_id, e1.id])

	_expect(is_equal_approx(friend.position.distance_to(e1.position),
		friend.position.distance_to(e2.position)),
		"E1/E2/E3 三者距离相同（裸距离排序无法区分，只能靠接近时间）")
	_expect(t1 < t2 and t1 < t3,
		"接近时间 %0.4f < %0.4f、%0.4f" % [t1, t2, t3])
	_expect(squad.target_id == e1.id,
		"选中 id=%d（接近时间最小），实际 id=%d" % [e1.id, squad.target_id])
	_expect(friend.target_id == e1.id,
		"个体镜像 unit.target_id 同步为 %d（实际 %d）" % [e1.id, friend.target_id])
	_expect(int(result["stats"]["candidates"]) == 3,
		"3 个候选全部参与排序（实际 %d）" % int(result["stats"]["candidates"]))


# ---------------------------------------------------------------- 用例 3：咬尾优先

func _case_3_ambush_priority() -> void:
	_header("3. 咬尾优先 —— recently_damaged 打开后，后方敌人优先于前方")
	# 没打标记：前方慢追兵接近时间更短 → 应该选前方
	var calm := _ambush_scenario(false)
	# 打上标记：后方目标优先
	var ambushed := _ambush_scenario(true)

	_info("未挨打：前方 id=%d 接近时间 %.4f s；后方 id=%d 接近时间 %.4f s → 选中 id=%d" % [
		calm["front_id"], calm["front_time"], calm["back_id"], calm["back_time"], calm["target"]])
	_info("挨打后：同一场景、同一组逼近速度 → 选中 id=%d" % ambushed["target"])

	_expect(calm["target"] == calm["front_id"],
		"未挨打时选中前方（id=%d，接近时间 %.4f < %.4f）" % [
			calm["front_id"], calm["front_time"], calm["back_time"]])
	_expect(ambushed["target"] == ambushed["back_id"],
		"挨打后选中后方（id=%d）" % ambushed["back_id"])
	_expect(calm["target"] != ambushed["target"],
		"同一个几何场景，只因为 recently_damaged 不同就换了目标（%d → %d）" % [
			calm["target"], ambushed["target"]])
	_expect(ambushed["front_behind"] == false and ambushed["back_behind"] == true,
		"方位判定正确：前方 behind=false、后方 behind=true")


## 构造"前后各一个追兵"的场景，返回选靶结果。
## 前方：800 m 外以 300 m/s 冲过来（接近时间 2.67 s）
## 后方：900 m 外以 100 m/s 追尾（接近时间 9 s）
func _ambush_scenario(damaged: bool) -> Dictionary:
	var friend := _make_unit(1, TEAM_BLUE, Vector3.ZERO, Vector3.FORWARD, 0.0)
	var front := _make_unit(2, TEAM_RED, Vector3(0.0, 0.0, -FRONT_DISTANCE),
		Vector3(0.0, 0.0, 1.0), FRONT_CLOSING)
	var back := _make_unit(3, TEAM_RED, Vector3(0.0, 0.0, BACK_DISTANCE),
		Vector3(0.0, 0.0, -1.0), BACK_CLOSING)
	if damaged:
		friend.mark_damaged()

	var friendlies: Array[Unit] = [friend]
	var enemies: Array[Unit] = [front, back]
	var squad: Squad = _select_target(friendlies, enemies)["squad"]
	return {
		"target": squad.target_id,
		"front_id": front.id,
		"back_id": back.id,
		"front_time": Targeting.approach_time(friend, front),
		"back_time": Targeting.approach_time(friend, back),
		"front_behind": (front.position - friend.position).normalized().dot(friend.forward) < 0.0,
		"back_behind": (back.position - friend.position).normalized().dot(friend.forward) < 0.0,
	}


# ---------------------------------------------------------------- 用例 4：状态转移

func _case_4_state_machine() -> void:
	_header("4. 状态转移 —— IDLE → MOVING → ATTACKING →（目标死亡）IDLE → MOVING")
	var session := _new_session()
	var friend := session.spawn_unit(SHIP_DEF_ID, Vector3.ZERO, TEAM_BLUE)
	var enemy := session.spawn_unit(SHIP_DEF_ID, ENEMY_POSITION, TEAM_RED)
	if friend == null or enemy == null:
		_expect(false, "spawn_unit 成功")
		session.shutdown()
		return

	_expect(friend.state == UnitStates.State.IDLE,
		"生成后 IDLE（%s）" % UnitStates.state_name(friend.state))

	CommandBus.issue([friend], BattleSession.CMD_ATTACK_MOVE,
		{"point": MOVE_TARGET, "source": &"verify"})
	session.tick(DT)
	_expect(friend.state == UnitStates.State.MOVING,
		"第 1 个 tick 后 MOVING（%s），航线 %d 点" % [
			UnitStates.state_name(friend.state), friend.route.size()])

	var log: Array[String] = ["tick 1: MOVING"]
	var attacking_tick := -1
	var last_state := friend.state
	for i in ATTACK_WAIT_TICKS:
		session.tick(DT)
		if friend.state != last_state:
			log.append("tick %d: %s" % [i + 2, UnitStates.state_name(friend.state)])
			last_state = friend.state
		if friend.state == UnitStates.State.ATTACKING:
			attacking_tick = i + 2
			break
	_info("转移序列：%s" % " → ".join(log))
	_info("扫描次数 = %d，候选 = %d，目标切换 = %d" % [
		int(session.targeting_stats()["scans"]), int(session.targeting_stats()["candidates"]),
		int(session.targeting_stats()["switches"])])

	_expect(attacking_tick > 0, "在 tick %d 进入 ATTACKING（射程 %.0f m 内）" % [
		attacking_tick, friend.weapon_range])
	_expect(friend.target_id == enemy.id,
		"ATTACKING 时个体目标 = 敌人 id=%d（实际 %d）" % [enemy.id, friend.target_id])
	_expect(attacking_tick > int(Targeting.SCAN_INTERVAL / DT),
		"ATTACKING 晚于第一次索敌扫描（tick %d > %d）：目标来自集中选靶，不是个体自己找的" % [
			attacking_tick, int(Targeting.SCAN_INTERVAL / DT)])

	# 目标死亡 → 下一 tick 退回 IDLE
	enemy.alive = false
	session.tick(DT)
	_expect(friend.state == UnitStates.State.IDLE,
		"目标死亡后 IDLE（%s）" % UnitStates.state_name(friend.state))

	# 航线还在 → 再下一 tick 回到 MOVING
	session.tick(DT)
	_expect(friend.state == UnitStates.State.MOVING,
		"航线仍活跃 → MOVING（%s）" % UnitStates.state_name(friend.state))
	_expect(friend.state_changes >= 4,
		"状态切换计数 %d ≥ 4（IDLE→MOVING→ATTACKING→IDLE→MOVING）" % friend.state_changes)
	session.shutdown()


# ---------------------------------------------------------------- 用例 5：目标死亡自动失效

func _case_5_target_death() -> void:
	_header("5. 目标死亡自动失效 —— target_id 清空且个体不报错")
	var session := _new_session()
	var friend := session.spawn_unit(SHIP_DEF_ID, Vector3.ZERO, TEAM_BLUE)
	var enemy := session.spawn_unit(SHIP_DEF_ID, ENEMY_POSITION, TEAM_RED)
	if friend == null or enemy == null:
		_expect(false, "spawn_unit 成功")
		session.shutdown()
		return

	CommandBus.issue([friend], BattleSession.CMD_ATTACK_MOVE,
		{"point": MOVE_TARGET, "source": &"verify"})
	for i in ATTACK_WAIT_TICKS:
		session.tick(DT)
		var squads_now := session.squads()
		if not squads_now.is_empty() and squads_now[0].has_target():
			break

	var squads := session.squads()
	_expect(not squads.is_empty(), "蓝队编队存在（%d 个编队）" % squads.size())
	if squads.is_empty():
		session.shutdown()
		return
	var squad: Squad = squads[0]
	_expect(squad.target_id == enemy.id,
		"清空之前确实锁着敌人（squad.target_id = %d）" % squad.target_id)

	# 击杀：alive = false（tick 第 8 步才会把它清出会话）
	enemy.alive = false
	var position_before := friend.position
	session.tick(DT)

	squads = session.squads()
	_expect(not squads.is_empty() and squads[0].target_id == Squad.NO_TARGET,
		"死亡后编队目标被清空（squad.target_id = %d）" % (
			Squad.NO_TARGET if squads.is_empty() else squads[0].target_id))
	_expect(friend.target_id == Squad.NO_TARGET,
		"个体镜像也清空（unit.target_id = %d）" % friend.target_id)
	_expect(session.stats()["units"] == 1,
		"死亡单位在 tick 第 8 步被清出会话（units = %d）" % session.stats()["units"])

	# 继续跑 30 tick：状态合法、单位还在动、不崩（push_error 会打到 stderr）
	var states := PackedStringArray()
	for i in 30:
		session.tick(DT)
		var name := UnitStates.state_name(friend.state)
		if not states.has(name):
			states.append(name)
	var moved := friend.position.distance_to(position_before)
	_info("死后继续 %d tick：状态集合 = %s，位移 %.2f m，units = %d" % [
		30, "/".join(states), moved, session.stats()["units"]])
	_expect(friend.state == UnitStates.State.MOVING,
		"死后仍按航线飞（状态 %s）" % UnitStates.state_name(friend.state))
	_expect(moved > 100.0, "死后 0.5 s 内仍有位移（%.2f m）" % moved)
	_expect(friend.target_id == Squad.NO_TARGET and not friend.recently_damaged,
		"个体字段干净（target_id = %d）" % friend.target_id)
	session.shutdown()


# ---------------------------------------------------------------- 用例 6：确定性

func _case_6_determinism() -> void:
	_header("6. 确定性 —— 相同输入跑两遍，目标与位置逐元素相同")
	var first := _run_determinism_scenario()
	var second := _run_determinism_scenario()

	var positions_a: Array[Vector3] = first["positions"]
	var positions_b: Array[Vector3] = second["positions"]
	_info("第一遍：目标 = %s，位置 = %s，扫描 = %d，切换 = %d" % [
		str(first["targets"]), _positions_text(positions_a),
		int(first["scans"]), int(first["switches"])])
	_info("第二遍：目标 = %s，位置 = %s，扫描 = %d，切换 = %d" % [
		str(second["targets"]), _positions_text(positions_b),
		int(second["scans"]), int(second["switches"])])

	_expect(positions_a.size() == positions_b.size(),
		"两遍单位数相同（%d vs %d）" % [positions_a.size(), positions_b.size()])
	var identical := positions_a.size() == positions_b.size()
	var worst := 0.0
	if identical:
		for i in positions_a.size():
			worst = maxf(worst, positions_a[i].distance_to(positions_b[i]))
			if positions_a[i] != positions_b[i]:
				identical = false
	_expect(identical, "最终位置逐元素相同（最大差 %.9f m）" % worst)
	_expect(first["targets"] == second["targets"],
		"目标选择完全相同：%s" % str(first["targets"]))
	_expect(first["scans"] == second["scans"] and first["switches"] == second["switches"],
		"诊断计数相同（扫描 %d/%d，切换 %d/%d）" % [
			int(first["scans"]), int(second["scans"]),
			int(first["switches"]), int(second["switches"])])


## 3v3 的固定场景：双方都 attack_move 到同一个远端，跑 300 tick。
func _run_determinism_scenario() -> Dictionary:
	var session := _new_session()
	var friendlies: Array[Unit] = []
	var spawns := [
		Vector3(0.0, 0.0, 0.0),
		Vector3(0.0, 0.0, 300.0),
		Vector3(0.0, 0.0, -300.0),
	]
	for position in spawns:
		var unit := session.spawn_unit(SHIP_DEF_ID, position, TEAM_BLUE)
		if unit != null:
			friendlies.append(unit)
	var enemy_spawns := [
		Vector3(0.0, 0.0, -3000.0),
		Vector3(500.0, 0.0, -3200.0),
		Vector3(-500.0, 0.0, -3000.0),
	]
	for position in enemy_spawns:
		session.spawn_unit(SHIP_DEF_ID, position, TEAM_RED)

	CommandBus.issue(friendlies, BattleSession.CMD_ATTACK_MOVE,
		{"point": MOVE_TARGET, "source": &"verify"})
	for i in DETERMINISM_TICKS:
		session.tick(DT)

	var positions: Array[Vector3] = []
	for unit in session.units():
		positions.append(unit.position)
	var targets: Array[int] = []
	for squad in session.squads():
		targets.append(squad.target_id)
	var stats := session.targeting_stats()
	var result := {
		"positions": positions,
		"targets": targets,
		"scans": int(stats["scans"]),
		"switches": int(stats["switches"]),
	}
	session.shutdown()
	return result


# ---------------------------------------------------------------- 附A：结构约束

func _case_a_structure() -> void:
	_header("附A. 结构约束 —— AI 层不是 Node；状态机不碰 position")
	var as_object: Object = UnitStates.new()
	_expect(as_object is RefCounted and not (as_object is Node),
		"UnitStates 是 RefCounted，不是 Node")
	as_object = Targeting.new()
	_expect(as_object is RefCounted and not (as_object is Node),
		"Targeting 是 RefCounted，不是 Node")
	as_object = Squad.new(1, 0)
	_expect(as_object is RefCounted and not (as_object is Node),
		"Squad 是 RefCounted，不是 Node")
	as_object = BattleContext.new()
	_expect(as_object is RefCounted and not (as_object is Node),
		"BattleContext 是 RefCounted，不是 Node")

	# 状态机只写状态字段：跑一次 step，position / forward / speed 一字未变
	var unit := _make_unit(9, TEAM_BLUE, Vector3(100.0, 0.0, -200.0), Vector3.FORWARD, 120.0)
	unit.set_route(PackedVector3Array([Vector3(100.0, 0.0, -2000.0)]))
	var before := unit.position
	var forward_before := unit.forward
	var speed_before := unit.speed
	var ctx := BattleContext.new()
	var units: Array[Unit] = [unit]
	var squads: Array[Squad] = []
	ctx.sync(units, squads, 0)
	UnitStates.step(unit, ctx, DT)
	_expect(unit.position == before and unit.forward == forward_before and unit.speed == speed_before,
		"UnitStates.step 不改 position / forward / speed（只改 state）")
	_expect(unit.state == UnitStates.State.MOVING,
		"有活航线 → MOVING（%s）" % UnitStates.state_name(unit.state))


# ---------------------------------------------------------------- 场景构造


func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


## 手搓一个只用来选靶 / 状态判定的 Unit（不参与移动积分）。
func _make_unit(p_id: int, p_team: int, position: Vector3,
		forward: Vector3, speed: float) -> Unit:
	var unit := Unit.new(p_id, SHIP_DEF_ID)
	unit.team = p_team
	unit.max_speed = 2000.0
	unit.acceleration = 200.0
	unit.deceleration = 200.0
	unit.turn_rate_yaw = deg_to_rad(30.0)
	unit.turn_rate_pitch = deg_to_rad(20.0)
	unit.radius = 20.0
	unit.weapon_range = WEAPON_RANGE
	unit.position = position
	unit.forward = forward.normalized()
	unit.speed = speed
	return unit


## 一次性选靶：手搓编队 + BattleContext + Targeting，扫一轮。
## dt 传满一个扫描间隔，保证这次 update 一定触发扫描（本用例只看"选了谁"）。
func _select_target(friendlies: Array[Unit], enemies: Array[Unit]) -> Dictionary:
	var squad := Squad.new(1, friendlies[0].team)
	for unit in friendlies:
		squad.add_unit(unit)
	var squads: Array[Squad] = [squad]
	var units: Array[Unit] = []
	units.append_array(friendlies)
	units.append_array(enemies)

	var ctx := BattleContext.new()
	ctx.sync(units, squads, 0)
	var targeting := Targeting.new()
	targeting.update(ctx, Targeting.SCAN_INTERVAL)
	return {"squad": squad, "stats": targeting.stats(), "ctx": ctx}


# ---------------------------------------------------------------- 输出工具


func _side_text(enemy: Unit, reference: Unit) -> String:
	var direction := (enemy.position - reference.position).normalized()
	return "前方" if direction.dot(reference.forward) >= 0.0 else "后方"


func _positions_text(positions: Array[Vector3]) -> String:
	var parts := PackedStringArray()
	for position in positions:
		parts.append("(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z])
	return " ".join(parts)


func _header(title: String) -> void:
	print("[verify] ---- %s" % title)


func _info(text: String) -> void:
	print("[verify]   %s" % text)


func _expect(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("[verify]   PASS  %s" % label)
		return
	_failures.append(label)
	print("[verify]   FAIL  %s" % label)


func _report() -> void:
	print("[verify] ---- 结果 ----")
	print("[verify]   断言 %d 条，失败 %d 条" % [_checks, _failures.size()])
	if _failures.is_empty():
		print("[verify] PASS")
		get_tree().quit(0)
		return
	for line in _failures:
		print("[verify]   失败：%s" % line)
	print("[verify] FAIL")
	get_tree().quit(1)
