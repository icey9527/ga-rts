extends Node3D

## T-3.2 验收：同队单位分离。
##
## 问题来源：5v5 诊断里两艘蓝舰坐标 `(0,80,1060)` 与 `(-0,80,1060)` —— 完全重合，
## 视觉上叠成一团。本场景验证软推开**既能把它们分开，又不把正在飞行的船推离航线**。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_separation.tscn

const DT := 1.0 / 60.0
const SHIP := "ou05"
const TEAM_BLUE := 0
const TEAM_RED := 1

## ou05 半径 32 → 目标间距 = (32 + 32) × 1.05 = 67.2 m
const SHIP_RADIUS := 32.0
const EXPECTED_GAP := (SHIP_RADIUS * 2.0) * 1.05
## 推进速度 30 m/s → 每 tick 每船 0.5 m，合计 1.0 m/tick。分离 67.2 m 约 68 tick，给 200
const SEPARATE_TICKS_MAX := 200

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_sep] ==== T-3.2 同队单位分离 ====")
	_case_1_full_overlap()
	_case_2_no_teleport()
	_case_3_stable()
	_case_4_enemy_not_separated()
	_case_5_degenerate_no_nan()
	_case_6_dead_ignored()
	_case_7_route_still_progresses()
	_case_8_determinism()

	print("[verify_sep] ---- 结果 ----")
	print("[verify_sep]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_sep] PASS")
		get_tree().quit(0)
	else:
		print("[verify_sep] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例

## 1. 完全重合的同队两船必须被分开到最小间距
func _case_1_full_overlap() -> void:
	_header("1. 完全重合 → 分离到最小间距（目标 %.1f m）" % EXPECTED_GAP)
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	_expect(a != null and b != null, "同队两艘在原点完全重合")
	if a == null or b == null:
		s.shutdown()
		return
	_expect(a.position.distance_to(b.position) < 0.01, "初始距离约 0")

	var ticks := 0
	while ticks < SEPARATE_TICKS_MAX:
		s.tick(DT)
		ticks += 1
		if a.position.distance_to(b.position) >= EXPECTED_GAP - 0.01:
			break

	var gap := a.position.distance_to(b.position)
	_info("  %d tick（%.1f 秒）后间距 %.2f m" % [ticks, float(ticks) * DT, gap])
	_expect(gap >= EXPECTED_GAP - 0.01, "间距达到最小间距（%.2f ≥ %.2f）" % [gap, EXPECTED_GAP - 0.01])
	_expect(gap <= EXPECTED_GAP + 1.0, "没有推过头（%.2f ≤ %.2f）" % [gap, EXPECTED_GAP + 1.0])
	_expect(int(s.stats()["separations"]) > 0,
		"分离计数已累加（%d）" % int(s.stats()["separations"]))
	s.shutdown()


## 2. 分离是渐进的：单 tick 位移不超过 MAX_PUSH_SPEED × dt
func _case_2_no_teleport() -> void:
	_header("2. 单 tick 位移受速度上限约束（不瞬移）")
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	_expect(a != null and b != null, "两艘重合")
	if a == null or b == null:
		s.shutdown()
		return

	var prev := a.position
	s.tick(DT)
	# 只统计**水平分量**：分离是水平行为；垂直方向归 UnitFlight 的高度软回拉（另一条通道）。
	# 两者混在一起测，会把“爬向巡航高度 80 m”误判成“分离推得太狠”。
	var step := _xz_length(a.position - prev)
	var limit := UnitSeparation.MAX_PUSH_SPEED * DT
	_info("  首 tick 水平位移 %.4f m（上限 %.4f m）" % [step, limit])
	_expect(step <= limit + 1.0e-4, "单 tick 水平位移 %.4f ≤ %.4f" % [step, limit])
	_expect(step > 0.0, "确实开始分开了（%0.4f m）" % step)
	s.shutdown()


## 3. 分开之后不再抖：继续跑，间距保持且位置基本不动
func _case_3_stable() -> void:
	_header("3. 分开后稳定（不来回抖）")
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	if a == null or b == null:
		_expect(false, "两艘重合")
		s.shutdown()
		return

	for i in SEPARATE_TICKS_MAX:
		s.tick(DT)
		if a.position.distance_to(b.position) >= EXPECTED_GAP - 0.01:
			break

	var gap_before := a.position.distance_to(b.position)
	var pos_a := a.position
	var pos_b := b.position
	for i in 120:
		s.tick(DT)
	var gap_after := a.position.distance_to(b.position)
	# 抖动看水平：垂直方向的残余变化是“向巡航高度 80 m 指数逼近”，不是抖
	var drift := maxf(_xz_length(a.position - pos_a), _xz_length(b.position - pos_b))

	_info("  再过 120 tick：间距 %.2f → %.2f，最大漂移 %.4f m" % [gap_before, gap_after, drift])
	_expect(gap_after >= EXPECTED_GAP - 0.01,
		"间距没有缩回（%.2f ≥ %.2f）" % [gap_after, EXPECTED_GAP - 0.01])
	_expect(drift < 0.5, "没有来回抖（漂移 %.4f m < 0.5）" % drift)
	s.shutdown()


## 4. 不同队不推开（设计行为：敌军要能贴脸交火）
func _case_4_enemy_not_separated() -> void:
	_header("4. 敌军不分离（保留贴脸交火能力）")
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_RED)
	if a == null or b == null:
		_expect(false, "两艘重合")
		s.shutdown()
		return

	for i in 60:
		s.tick(DT)
	var gap := a.position.distance_to(b.position)
	_info("  60 tick 后敌军间距 %.2f m" % gap)
	_expect(gap < 1.0, "敌军没有被推开（%.2f m，仍贴在一起）" % gap)
	_expect(int(s.stats()["separations"]) == 0, "分离计数为 0")
	s.shutdown()


## 5. 完全重合时不能算出 NaN（0 向量归一化是经典陷阱）
func _case_5_degenerate_no_nan() -> void:
	_header("5. 完全重合不产生 NaN")
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	if a == null or b == null:
		_expect(false, "两艘重合")
		s.shutdown()
		return

	for i in 30:
		s.tick(DT)
	var pa := a.position
	var pb := b.position
	_info("  a = (%.2f, %.2f, %.2f)  b = (%.2f, %.2f, %.2f)" % [
		pa.x, pa.y, pa.z, pb.x, pb.y, pb.z])
	_expect(pa.is_finite(), "a 的位置是有限值（无 NaN / Inf）")
	_expect(pb.is_finite(), "b 的位置是有限值（无 NaN / Inf）")
	_expect(pa.distance_to(pb) > 0.0, "两者已经分开（%.4f m）" % pa.distance_to(pb))
	s.shutdown()


## 6. 死亡单位不参与分离
func _case_6_dead_ignored() -> void:
	_header("6. 死亡单位不参与分离")
	var s := _new_session()
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	if a == null or b == null:
		_expect(false, "两艘重合")
		s.shutdown()
		return

	b.alive = false
	var before := a.position
	for i in 30:
		s.tick(DT)
	# 死人会在第 8 步被清掉，活人不该被它推。同样只看水平（垂直是爬升）
	var moved := _xz_length(a.position - before)
	_info("  存活单位位移 %.4f m（死亡单位未推开它）" % moved)
	_expect(moved < 1.0, "活人没被尸体推开（%.4f m < 1.0）" % moved)
	_expect(s.unit_count() == 1, "死亡单位已被清理（剩 %d）" % s.unit_count())
	s.shutdown()


## 7. 分离不能把正在飞行的船推离航线
func _case_7_route_still_progresses() -> void:
	_header("7. 有航线时仍能正常前进")
	var s := _new_session()
	var goal := Vector3(0.0, 0.0, -3000.0)
	var a := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	var b := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	if a == null or b == null:
		_expect(false, "两艘重合")
		s.shutdown()
		return

	CommandBus.issue([a], BattleSession.CMD_MOVE, {"point": goal, "source": &"verify"})
	var start_dist := a.position.distance_to(goal)
	for i in 180:
		s.tick(DT)
	var end_dist := a.position.distance_to(goal)
	var gap := a.position.distance_to(b.position)
	_info("  180 tick（3 s）后：距目标 %.1f → %.1f m，与僚舰间距 %.2f m" % [
		start_dist, end_dist, gap])
	_expect(end_dist < start_dist - 100.0,
		"确实朝目标飞了（缩短 %.1f m）" % (start_dist - end_dist))
	_expect(gap >= EXPECTED_GAP - 0.01, "与僚舰保持了间距（%.2f m）" % gap)
	s.shutdown()


## 8. 确定性：同输入两次跑，最终位置逐元素相同
func _case_8_determinism() -> void:
	_header("8. 确定性")
	var first := _run_scenario()
	var second := _run_scenario()
	var same := true
	for i in first.size():
		if not (first[i] as Vector3).is_equal_approx(second[i]):
			same = false
	_expect(same, "两次运行的最终位置逐元素相同")


func _run_scenario() -> Array[Vector3]:
	var s := _new_session()
	var units: Array[Unit] = []
	for i in 4:
		var u := s.spawn_unit(SHIP, Vector3(float(i % 2) * 10.0, 0.0, 0.0), TEAM_BLUE)
		if u != null:
			units.append(u)
	CommandBus.issue(units, BattleSession.CMD_MOVE,
		{"point": Vector3(0.0, 0.0, -2000.0), "source": &"verify"})
	for i in 150:
		s.tick(DT)
	var out: Array[Vector3] = []
	for u in s.units():
		out.append(u.position)
	s.shutdown()
	return out


# ---------------------------------------------------------------- 工具

func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


## 水平（XZ）长度。分离只在水平面作用，垂直归高度软回拉，两者必须分开统计。
func _xz_length(v: Vector3) -> float:
	return Vector2(v.x, v.z).length()


func _header(text: String) -> void:
	print("[verify_sep] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_sep] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_sep]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_sep]   FAIL  %s" % what)
