extends Node3D

## T-2.3 验收：弹体与扫掠命中（ADR-0013）。
##
## 本场景的重点不是“能不能打中”，而是**点判定会漏、扫掠不会漏**：
## 弹速 2000 m/s、固定 60 Hz → 每 tick 走 33.3 m，而舰体直径只有 10 m，
## 用「当前位置是否在球内」判定必然跳过目标。
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_projectile.tscn

const TICK := 1.0 / 60.0
const PROJ_SPEED := 2000.0
const PROJ_RADIUS := 0.8
const TARGET_RADIUS := 5.0

var _fails := 0
var _checks := 0


func _ready() -> void:
	print("[verify_proj] ==== T-2.3 弹体与扫掠命中 ====")
	_case_1_high_speed_sweep()
	_case_2_miss()
	_case_3_same_team()
	_case_4_nearest_first()
	_case_5_lifetime()
	_case_6_no_side_effect()
	_case_7_determinism()

	print("[verify_proj] ---- 结果 ----")
	print("[verify_proj]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_proj] PASS")
		get_tree().quit(0)
	else:
		print("[verify_proj] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例

## 1. 高速穿透：两个端点都在球外，但线段穿过球 → 必须命中
func _case_1_high_speed_sweep() -> void:
	_info("---- 1. 高速穿透（点判定必漏，扫掠必中）")
	var mgr := ProjectileManager.new()
	var target := _make_unit(1, 2, Vector3(1000.0, 0.0, 0.0), TARGET_RADIUS)

	# 起点刻意错开半步，保证没有任何一 tick 的「点」落在球内
	var step := PROJ_SPEED * TICK
	var p := mgr.spawn(Vector3(-step * 0.5, 0.0, 0.0), Vector3.RIGHT, PROJ_SPEED,
		100.0, 1, 99, PROJ_RADIUS, 4.0)

	var hit_record: Dictionary = {}
	for i in 60:
		var hits := mgr.tick([target] as Array, TICK)
		if not hits.is_empty():
			hit_record = hits[0]
			break

	_expect(not hit_record.is_empty(), "高速弹命中了目标")
	if hit_record.is_empty():
		return

	# 关键证据：命中那一刻，弹体的**起点与终点都在球外**
	var d_prev := p.prev_position.distance_to(target.position)
	var d_curr := p.position.distance_to(target.position)
	_info("  每 tick 位移 %.2f m，目标球半径 %.1f m" % [p.travel_distance(), TARGET_RADIUS])
	_info("  命中时 起点距球心 %.2f m、终点距球心 %.2f m（都 > %.1f → 点判定必漏）" % [
		d_prev, d_curr, TARGET_RADIUS])
	_expect(d_prev > TARGET_RADIUS, "命中时起点在球外（%.2f > %.1f）" % [d_prev, TARGET_RADIUS])
	_expect(d_curr > TARGET_RADIUS, "命中时终点在球外（%.2f > %.1f）" % [d_curr, TARGET_RADIUS])
	_expect(p.travel_distance() > TARGET_RADIUS * 2.0,
		"单 tick 位移 %.2f m 远大于目标直径 %.1f m" % [p.travel_distance(), TARGET_RADIUS * 2.0])

	# 命中点应当落在「组合球面」上：扫掠用的是 目标半径 + 弹体半径
	var combined := TARGET_RADIUS + PROJ_RADIUS
	var miss: float = (hit_record["point"] as Vector3).distance_to(target.position)
	_expect(absf(miss - combined) < 0.5,
		"命中点在组合球面上（距球心 %.3f，期望 %.1f ± 0.5 = 目标 %.1f + 弹体 %.1f）" % [
			miss, combined, TARGET_RADIUS, PROJ_RADIUS])
	_expect(int(hit_record["target_id"]) == target.id, "命中的是正确目标")
	_expect(mgr.stats()["active"] == 0, "命中后弹体已移除")


## 2. 未命中：目标偏离弹道
func _case_2_miss() -> void:
	_info("---- 2. 未命中（目标偏离弹道）")
	var mgr := ProjectileManager.new()
	var target := _make_unit(1, 2, Vector3(500.0, 0.0, 400.0), TARGET_RADIUS)
	var p := mgr.spawn(Vector3.ZERO, Vector3.RIGHT, PROJ_SPEED, 100.0, 1, 99, PROJ_RADIUS, 4.0)
	var total := 0
	for i in 30:
		total += mgr.tick([target] as Array, TICK).size()
	_expect(total == 0, "偏离弹道的目标不会被命中（命中 %d 次）" % total)
	_expect(p.alive, "弹体仍在飞（未命中不销毁）")


## 3. 同队/自己不打自己
func _case_3_same_team() -> void:
	_info("---- 3. 同队与自身不判命中")
	var mgr := ProjectileManager.new()
	var ally := _make_unit(1, 1, Vector3(300.0, 0.0, 0.0), TARGET_RADIUS)
	var self_unit := _make_unit(2, 1, Vector3(600.0, 0.0, 0.0), TARGET_RADIUS)
	var hits := 0
	mgr.spawn(Vector3.ZERO, Vector3.RIGHT, PROJ_SPEED, 100.0, 1, self_unit.id, PROJ_RADIUS, 4.0)
	for i in 30:
		hits += mgr.tick([ally, self_unit] as Array, TICK).size()
	_expect(hits == 0, "同队（team=1）与发射者自身都不被命中（实际 %d 次）" % hits)


## 4. 同一条线上有多个目标：最近的先中
func _case_4_nearest_first() -> void:
	_info("---- 4. 一线上多目标：最近者优先")
	var mgr := ProjectileManager.new()
	var near := _make_unit(1, 2, Vector3(200.0, 0.0, 0.0), TARGET_RADIUS)
	var far := _make_unit(2, 2, Vector3(800.0, 0.0, 0.0), TARGET_RADIUS)
	var rec: Dictionary = {}
	mgr.spawn(Vector3.ZERO, Vector3.RIGHT, PROJ_SPEED, 100.0, 1, 99, PROJ_RADIUS, 4.0)
	for i in 30:
		var hits := mgr.tick([far, near] as Array, TICK)
		if not hits.is_empty():
			rec = hits[0]
			break
	_expect(not rec.is_empty(), "命中了某个目标")
	_expect(int(rec.get("target_id", -1)) == near.id,
		"命中的是最近的那个（实际 target_id=%d，期望 %d）" % [int(rec.get("target_id", -1)), near.id])


## 5. 生命期到期自动消失
func _case_5_lifetime() -> void:
	_info("---- 5. 生命期到期自动消失")
	var mgr := ProjectileManager.new()
	mgr.spawn(Vector3.ZERO, Vector3.RIGHT, 100.0, 100.0, 1, 99, PROJ_RADIUS, 0.05)
	_expect(mgr.active_count() == 1, "刚生成时有 1 发在飞")
	for i in 10:
		mgr.tick([] as Array, TICK)
	_expect(mgr.active_count() == 0, "生命期结束后自动移除（剩 %d）" % mgr.active_count())
	_expect(mgr.stats()["expired"] >= 1, "过期计数已累加")


## 6. 命中不产生副作用：Manager 不改单位状态（伤害由调用方结算）
func _case_6_no_side_effect() -> void:
	_info("---- 6. 命中本身不结算伤害（ADR-0013 解耦）")
	var mgr := ProjectileManager.new()
	var target := _make_unit(1, 2, Vector3(300.0, 0.0, 0.0), TARGET_RADIUS)
	target.hp = 1000.0
	target.max_hp = 1000.0
	var hp_before := target.hp
	var taken_before := target.damage_taken

	mgr.spawn(Vector3.ZERO, Vector3.RIGHT, PROJ_SPEED, 250.0, 1, 99, PROJ_RADIUS, 4.0)
	for i in 30:
		mgr.tick([target] as Array, TICK)

	_expect(is_equal_approx(target.hp, hp_before),
		"Manager 不改 hp（%.1f → %.1f）" % [hp_before, target.hp])
	_expect(is_equal_approx(target.damage_taken, taken_before),
		"Manager 不改 damage_taken（%.1f → %.1f）" % [taken_before, target.damage_taken])
	_expect(target.recently_damaged == false, "Manager 不改 recently_damaged")

	# 由调用方（session）结算，才算数
	var lethal := target.apply_damage(250.0)
	_expect(not lethal, "250 伤害不足以击毁 1000 hp")
	_expect(is_equal_approx(target.hp, hp_before - 250.0), "apply_damage 生效（hp=%.1f）" % target.hp)
	_expect(target.recently_damaged, "apply_damage 会置 recently_damaged（供索敌用）")

	# 致死
	target.apply_damage(1000.0)
	_expect(not target.alive, "超出 hp 时单位死亡")
	_expect(is_equal_approx(target.hp, 0.0), "hp 不会为负")


## 7. 确定性：同输入两次跑出完全相同的命中记录
func _case_7_determinism() -> void:
	_info("---- 7. 确定性")
	var a := _run_scenario()
	var b := _run_scenario()
	_expect(a.size() == b.size(), "两次命中次数相同（%d vs %d）" % [a.size(), b.size()])
	var same := a.size() == b.size()
	if same:
		for i in a.size():
			if not (a[i]["point"] as Vector3).is_equal_approx(b[i]["point"]):
				same = false
			if int(a[i]["target_id"]) != int(b[i]["target_id"]):
				same = false
	_expect(same, "两次命中点与目标逐条相同")


func _run_scenario() -> Array:
	var mgr := ProjectileManager.new()
	var t1 := _make_unit(1, 2, Vector3(400.0, 0.0, 0.0), TARGET_RADIUS)
	var t2 := _make_unit(2, 2, Vector3(900.0, 12.0, 0.0), TARGET_RADIUS)
	mgr.spawn(Vector3.ZERO, Vector3.RIGHT, PROJ_SPEED, 100.0, 1, 99, PROJ_RADIUS, 4.0)
	var out: Array = []
	for i in 40:
		out.append_array(mgr.tick([t1, t2] as Array, TICK))
	return out


# ---------------------------------------------------------------- 工具

func _make_unit(id: int, team: int, pos: Vector3, radius: float) -> Unit:
	var u := Unit.new(id, "fake")
	u.team = team
	u.position = pos
	u.radius = radius
	u.alive = true
	u.hp = 100.0
	u.max_hp = 100.0
	return u


func _info(text: String) -> void:
	print("[verify_proj] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_proj]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_proj]   FAIL  %s" % what)
