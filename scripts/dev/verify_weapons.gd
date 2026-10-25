extends Node3D

## 武器数据与炮塔转向验证场景（T-2.2，开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path F:\godot\ga-rts \
##         scenes/dev/verify_weapons.tscn
##     通过 → exit 0    失败 → exit 1
##
## 覆盖 7 条验收点：
##   1. 转向限速：每 tick 转角 ≤ tracking_rate × dt
##   2. 夹角未到不能开火（目标在射程内）
##   3. 转到位能开火
##   4. 冷却阻挡：开火后未归零不能开火，归零后恢复
##   5. 射程外不能开火
##   6. 多炮塔 spread：count=4 → 4 个 mount 且 local_offset 互不相同（走真实 TBL）
##   7. 确定性：同输入跑两次，aim_direction 逐元素相同
##
## 炮塔层全是 RefCounted（WeaponDef / WeaponMount / UnitWeapons），根节点只为能被 --path 拉起来。
## 本场景**不生弹体 / 不判命中 / 不算伤害** —— 那是 T-2.3。

## 模拟步长（与 Simulation.TICK_RATE = 60 一致）
const DT := 1.0 / 60.0
## 被测炮塔转速（度/秒）—— 90° 侧方要 2 s 转到位
const TRACKING_DEG := 45.0
## 单 tick 转角判定的浮点容差（度）：旋转 + 归一化的舍入残差实测 ~3e-6°，留给噪声而不是算法
const ANGLE_EPSILON := 1.0e-3
## 用例 1 的观测上限（120 tick = 2 s 转 90°）
const TRACK_TICKS := 240

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	await get_tree().process_frame

	_case_1_tracking_rate()
	_case_2_out_of_cone()
	_case_3_aligned_fires()
	_case_4_cooldown()
	_case_5_out_of_range()
	_case_6_spread()
	_case_7_determinism()

	_report()


# ---------------------------------------------------------------- 用例 1

func _case_1_tracking_rate() -> void:
	_header("1. 转向限速 —— 正前方 → 正右方 90°，每 tick 转角 ≤ %.0f°/s × dt" % TRACKING_DEG)
	var unit := _make_unit()
	var mount := _make_mount(_make_def(400.0, 2000.0, 3.0, TRACKING_DEG, 5.0), unit)
	var target := Vector3(500.0, 0.0, 0.0)  # 正右方（forward = -Z，右舷 = +X）

	var max_step := 0.0
	var ticks := 0
	while ticks < TRACK_TICKS:
		var before := mount.aim_direction
		mount.aim_at(unit, target, DT)
		max_step = maxf(max_step, rad_to_deg(before.angle_to(mount.aim_direction)))
		ticks += 1
		if mount.aim_error(unit, target) < deg_to_rad(0.01):
			break

	var limit := TRACKING_DEG * DT
	var final_error := rad_to_deg(mount.aim_error(unit, target))
	_info("每 tick 转角上限 = %.6f°；实测最大 %.6f°（%.2f tick 转完 90°）" % [limit, max_step, ticks])
	_info("最终夹角 = %.6f°，aim_direction = %s" % [final_error, _short(mount.aim_direction)])
	_expect(max_step <= limit + ANGLE_EPSILON, "每 tick 转角 ≤ %.6f°（实测 %.6f°）" % [limit, max_step])
	_expect(final_error <= 0.01, "转到位后夹角 ≤ 0.01°（实测 %.6f°）" % final_error)
	_expect(ticks <= TRACK_TICKS, "在 %d tick 内转完 90°（实测 %d）" % [TRACK_TICKS, ticks])


# ---------------------------------------------------------------- 用例 2

func _case_2_out_of_cone() -> void:
	_header("2. 夹角未到不能开火 —— 射程内（300 m）但夹角 90° > 容差 5°")
	var unit := _make_unit()
	var mount := _make_mount(_make_def(400.0, 2000.0, 3.0, TRACKING_DEG, 5.0), unit)
	var target := Vector3(300.0, 0.0, 0.0)
	var distance := mount.world_position(unit).distance_to(target)
	var error_deg := rad_to_deg(mount.aim_error(unit, target))
	_info("距离 = %.1f m（射程 %.0f），夹角 = %.3f°（容差 %.1f°），冷却 = %.2f s" % [
		distance, mount.def.range, error_deg, mount.def.aim_tolerance, mount.cooldown_left])
	_expect(distance <= mount.def.range, "目标确在射程内（%.1f ≤ %.0f）" % [distance, mount.def.range])
	_expect(error_deg > mount.def.aim_tolerance, "夹角确大于容差（%.3f° > %.1f°）" % [
		error_deg, mount.def.aim_tolerance])
	_expect(not mount.can_fire(unit, target), "can_fire = false（冷却已好也不算能开火）")


# ---------------------------------------------------------------- 用例 3

func _case_3_aligned_fires() -> void:
	_header("3. 转到位能开火 —— 持续 aim 直到夹角 < 容差")
	var unit := _make_unit()
	var mount := _make_mount(_make_def(400.0, 2000.0, 3.0, TRACKING_DEG, 5.0), unit)
	var target := Vector3(300.0, 0.0, 0.0)
	var ticks := 0
	while ticks < TRACK_TICKS and not mount.can_fire(unit, target):
		mount.aim_at(unit, target, DT)
		ticks += 1
	var error_deg := rad_to_deg(mount.aim_error(unit, target))
	_info("%d tick（%.3f s）后夹角 = %.6f°，can_fire = %s" % [
		ticks, ticks * DT, error_deg, str(mount.can_fire(unit, target))])
	_expect(mount.can_fire(unit, target), "转到位后 can_fire = true")
	_expect(error_deg <= mount.def.aim_tolerance, "夹角 %.6f° ≤ 容差 %.1f°" % [
		error_deg, mount.def.aim_tolerance])


# ---------------------------------------------------------------- 用例 4

func _case_4_cooldown() -> void:
	_header("4. 冷却阻挡 —— 开火后 cooldown_left 未归零不能开火，归零后恢复")
	var unit := _make_unit()
	var def := _make_def(400.0, 2000.0, 3.0, TRACKING_DEG, 5.0)
	var mount := _make_mount(def, unit)
	var target := Vector3(0.0, 0.0, -600.0)  # 正前方，夹角 0
	mount.aim_at(unit, target, DT)
	_expect(mount.can_fire(unit, target), "开火前 can_fire = true")

	mount.consume_cooldown()
	_info("consume_cooldown() → cooldown_left = %.3f s（TBL cooldown = %.2f s）" % [
		mount.cooldown_left, def.cooldown])
	_expect(is_equal_approx(mount.cooldown_left, def.cooldown), "开火后 cooldown_left = %.2f s" % def.cooldown)
	_expect(not mount.can_fire(unit, target), "冷却中 can_fire = false")

	mount.tick_cooldown(def.cooldown * 0.5)
	_info("tick_cooldown(%.2f s) → cooldown_left = %.3f s，can_fire = %s" % [
		def.cooldown * 0.5, mount.cooldown_left, str(mount.can_fire(unit, target))])
	_expect(not mount.can_fire(unit, target), "冷却过半仍 can_fire = false")

	mount.tick_cooldown(def.cooldown)
	_info("tick_cooldown(%.2f s) → cooldown_left = %.3f s，can_fire = %s" % [
		def.cooldown, mount.cooldown_left, str(mount.can_fire(unit, target))])
	_expect(mount.cooldown_left == 0.0, "冷却不越过 0（实际 %.3f）" % mount.cooldown_left)
	_expect(mount.can_fire(unit, target), "冷却归零后 can_fire = true")

	# UnitWeapons.tick 层：tick 自己扣冷却，所以能开火的那个 tick 之后必须安静到冷却结束
	var weapons := UnitWeapons.new()
	weapons.add_mount(mount)
	var first := weapons.tick(unit, target, DT)
	var second := weapons.tick(unit, target, DT)
	_info("UnitWeapons.tick 连续两 tick 的想开火数 = %d, %d" % [first, second])
	_expect(first == 1, "冷却好了的 tick 想开火数 = 1（实测 %d）" % first)
	_expect(second == 0, "紧随其后的 tick 想开火数 = 0（实测 %d）" % second)


# ---------------------------------------------------------------- 用例 5

func _case_5_out_of_range() -> void:
	_header("5. 射程外不能开火 —— 正前方，夹角 0°")
	var unit := _make_unit()
	var def := _make_def(400.0, 700.0, 3.0, TRACKING_DEG, 5.0)
	var mount := _make_mount(def, unit)
	var inside := Vector3(0.0, 0.0, -(def.range - 1.0))
	var outside := Vector3(0.0, 0.0, -(def.range + 1.0))
	mount.aim_at(unit, inside, DT)
	var error_deg := rad_to_deg(mount.aim_error(unit, outside))
	_info("射程 = %.0f m；内侧 %.0f m → can_fire=%s；外侧 %.0f m（夹角 %.4f°）→ can_fire=%s" % [
		def.range, def.range - 1.0, str(mount.can_fire(unit, inside)),
		def.range + 1.0, error_deg, str(mount.can_fire(unit, outside))])
	_expect(mount.can_fire(unit, inside), "射程内侧 1 m 能开火")
	_expect(not mount.can_fire(unit, outside), "射程外侧 1 m 不能开火")
	_expect(error_deg <= def.aim_tolerance, "外侧目标的夹角本身在容差内（%.4f° ≤ %.1f°）" % [
		error_deg, def.aim_tolerance])


# ---------------------------------------------------------------- 用例 6

func _case_6_spread() -> void:
	_header("6. 多炮塔 spread —— 走真实 TBL（ou134 / heavy_beam），count = 4")
	var registry := Registry.new()
	var loaded := registry.load_all()
	_info("Registry.load_all() = %s（错误 %d / 警告 %d）" % [
		str(loaded), registry.errors.size(), registry.warnings.size()])
	_expect(loaded, "注册表加载零错误")
	var weapon_ids := registry.ids_of("weapons")
	_info("已注册武器：%s" % ", ".join(weapon_ids))
	_expect(weapon_ids.has("heavy_beam") and weapon_ids.has("pulse_cannon"),
		"weapons 类别扫到 heavy_beam 与 pulse_cannon")

	# 两把武器的设计口径：重炮高伤慢射远，快炮低伤快射近
	var heavy := WeaponDef.from_record("heavy_beam", registry.weapon("heavy_beam"))
	var pulse := WeaponDef.from_record("pulse_cannon", registry.weapon("pulse_cannon"))
	_info("heavy_beam：dmg=%.0f range=%.0f cd=%.2f track=%.0f°/s cone=%.1f°" % [
		heavy.damage, heavy.range, heavy.cooldown, heavy.tracking_rate, heavy.aim_tolerance])
	_info("pulse_cannon：dmg=%.0f range=%.0f cd=%.2f track=%.0f°/s cone=%.1f°" % [
		pulse.damage, pulse.range, pulse.cooldown, pulse.tracking_rate, pulse.aim_tolerance])
	_expect(heavy.is_valid() and pulse.is_valid(), "两把武器的 TBL 字段完整")
	_expect(heavy.damage > pulse.damage and heavy.cooldown > pulse.cooldown
		and heavy.range > pulse.range and heavy.tracking_rate < pulse.tracking_rate,
		"重炮高伤/慢射/远射，快炮低伤/快射/近射")

	var ctx := BattleContext.new()
	ctx.bind_registry(registry)
	var unit := Unit.new(1, "ou134")
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	var weapons := UnitWeapons.build(unit, "ou134", ctx)
	var mounts := weapons.mounts()
	_info("UnitWeapons.build(ou134) → %d 个炮塔：%s" % [
		mounts.size(), ", ".join(_offsets_text(mounts))])
	_expect(mounts.size() == 4, "count = 4 → 生成 4 个 mount（实测 %d）" % mounts.size())

	var distinct := true
	for i in mounts.size():
		for j in range(i + 1, mounts.size()):
			if mounts[i].local_offset.is_equal_approx(mounts[j].local_offset):
				distinct = false
	_expect(distinct, "4 个 local_offset 两两互不相同")
	_expect(mounts[0].def == mounts[3].def and mounts[0].def.id == "heavy_beam",
		"4 个炮塔共用同一把武器 heavy_beam")


# ---------------------------------------------------------------- 用例 7

func _case_7_determinism() -> void:
	_header("7. 确定性 —— 同输入跑两次，aim_direction 逐元素相同")
	var first := _aim_sequence()
	var second := _aim_sequence()
	var mismatches := 0
	for i in first.size():
		var a: Vector3 = first[i]
		var b: Vector3 = second[i]
		if a.x != b.x or a.y != b.y or a.z != b.z:
			mismatches += 1
	_info("两次各 %d tick（4 个炮塔，各带 spread 偏移）" % first.size())
	_info("末 tick：%s vs %s" % [_short(first[first.size() - 1]), _short(second[second.size() - 1])])
	_expect(mismatches == 0, "逐元素不一致的 tick 数 = 0（实测 %d）" % mismatches)

	# 对照组：初始朝向差 1 mrad，前 30 tick 必须跑出不同结果
	# （否则上面的相等可能只是“都把数值转到了收敛点”，不是确定性）
	var control := _aim_sequence(Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, 0.001))
	var differs := 0
	for i in 30:
		if control[i].x != first[i].x:
			differs += 1
	_info("对照组（初始朝向偏 1 mrad）前 30 tick 中有 %d tick 与基线不同；末 tick x = %.9f vs %.9f" % [
		differs, control[control.size() - 1].x, first[first.size() - 1].x])
	_expect(differs > 0, "对照组确实跑出不同结果（说明相等的来源是确定性，不是常量）")


## 固定的 90 tick 瞄准序列：4 个炮塔（count=4 的 spread），目标在右前上方
func _aim_sequence(initial_aim := Vector3.FORWARD) -> Array[Vector3]:
	var unit := _make_unit()
	var def := _make_def(400.0, 2000.0, 3.0, TRACKING_DEG, 5.0)
	var weapons := UnitWeapons.new()
	for i in 4:
		var mount := WeaponMount.new()
		mount.def = def
		mount.local_offset = Vector3(0.0, 4.5, 0.0) * (float(i) - 1.5)
		mount.aim_direction = initial_aim
		weapons.add_mount(mount)
	var target := Vector3(600.0, 120.0, -300.0)
	var out: Array[Vector3] = []
	for tick in 90:
		weapons.tick(unit, target, DT)
		out.append(weapons.mounts()[3].aim_direction)
	return out


# ---------------------------------------------------------------- 夹具


func _make_unit() -> Unit:
	var unit := Unit.new(1, "verify_weapons")
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.speed = 0.0
	unit.radius = 20.0
	return unit


func _make_mount(def: WeaponDef, unit: Unit) -> WeaponMount:
	var mount := WeaponMount.new()
	mount.def = def
	mount.local_offset = Vector3.ZERO
	mount.aim_direction = unit.forward
	mount.cooldown_left = 0.0
	return mount


func _make_def(damage: float, range_m: float, cooldown: float,
		tracking: float, tolerance: float) -> WeaponDef:
	var def := WeaponDef.new()
	def.id = "test_gun"
	def.display_name = "测试炮"
	def.damage = damage
	def.range = range_m
	def.cooldown = cooldown
	def.projectile_speed = 1600.0
	def.tracking_rate = tracking
	def.aim_tolerance = tolerance
	return def


# ---------------------------------------------------------------- 输出工具


func _short(v: Vector3) -> String:
	return "(%.6f, %.6f, %.6f)" % [v.x, v.y, v.z]


func _offsets_text(mounts: Array[WeaponMount]) -> PackedStringArray:
	var parts := PackedStringArray()
	for mount in mounts:
		parts.append(_short(mount.local_offset))
	return parts


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
