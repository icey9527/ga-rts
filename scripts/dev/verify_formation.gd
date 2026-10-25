extends Node3D

## T-3.3 验收：编队阵型槽位。
##
## 要证明的不是"阵型函数算得对"（那是纯几何，用例 1~3 顺手带过），
## 而是**多单位移动命令不再让所有人挤向同一个点**：
##   · 每艘船拿到自己的槽位，到达后彼此分开
##   · 换阵型会让队形真的重排（不是只改一个枚举值）
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_formation.tscn

const DT := 1.0 / 60.0
const SHIP := "ou05"
const TEAM_BLUE := 0

## ou05 半径 32 → 阵型间距 = 32 × 2 × 1.3 = 83.2 m
const SHIP_RADIUS := 32.0
const EXPECTED_SPACING := SHIP_RADIUS * 2.0 * 1.3
## 分离系统的最小间距（同 T-3.2）
const MIN_SEPARATION := (SHIP_RADIUS * 2.0) * 1.05

## 落点：正前方 1500 m（forward = -Z，所以 LINE 沿 X 展开、COLUMN 沿 Z 展开）
const DEST := Vector3(0.0, 0.0, -1500.0)
const ARRIVE_TICKS_MAX := 1800
## 判定"到槽位"的容差：半个间距。足够区分相邻槽位，又不会被转向噪声打翻
const SLOT_TOLERANCE := EXPECTED_SPACING * 0.5

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_form] ==== T-3.3 编队阵型 ====")
	_case_1_geometry()
	_case_2_to_world()
	_case_3_group_move_line()
	_case_4_group_move_wedge()
	_case_5_switch_midflight()
	_case_6_single_unit_no_slot()
	_case_7_idempotent()
	_case_8_determinism()

	print("[verify_form] ---- 结果 ----")
	print("[verify_form]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_form] PASS")
		get_tree().quit(0)
	else:
		print("[verify_form] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例 1~2：纯几何

## 1. 槽位几何本身
func _case_1_geometry() -> void:
	_header("1. 槽位几何（纯函数）")
	var s := 100.0
	var line := Formation.slot_offsets(5, Formation.Kind.LINE, s)
	_expect(line.size() == 5, "横队 5 人 → 5 个槽位")
	var xs := PackedFloat32Array()
	for o in line:
		xs.append(o.x)
	_expect(_max_of(xs) - _min_of(xs) == 400.0,
		"横队 X 跨度 = (5-1)×100 = 400（实际 %.1f）" % (_max_of(xs) - _min_of(xs)))
	var z_span := 0.0
	for o in line:
		z_span = maxf(z_span, absf(o.z))
	_expect(z_span < 0.001, "横队全部同一纵深（z 跨度 %.4f）" % z_span)
	_expect(_centroid_of(line).length() < 0.001,
		"槽位已去重心（重心 %.4f）" % _centroid_of(line).length())
	_expect(_all_distinct(line), "5 个槽位互不重合")

	var column := Formation.slot_offsets(4, Formation.Kind.COLUMN, s)
	var zs := PackedFloat32Array()
	for o in column:
		zs.append(o.z)
	_expect(_max_of(zs) - _min_of(zs) == 300.0,
		"纵队 Z 跨度 = (4-1)×100 = 300（实际 %.1f）" % (_max_of(zs) - _min_of(zs)))

	var wedge := Formation.slot_offsets(5, Formation.Kind.WEDGE, s)
	_expect(wedge.size() == 5, "楔形 5 人 → 5 个槽位")
	_expect(_all_distinct(wedge), "楔形槽位互不重合")
	# 去重心后，领队应对应最小的 z
	var min_z := INF
	var min_i := -1
	for i in wedge.size():
		if wedge[i].z < min_z:
			min_z = wedge[i].z
			min_i = i
	_expect(min_i == 0, "楔形领队（槽位 0）在最前（实际 z 最小的是槽位 %d）" % min_i)

	var box := Formation.slot_offsets(9, Formation.Kind.BOX, s)
	_expect(box.size() == 9, "方阵 9 人 → 9 个槽位")
	_expect(_all_distinct(box), "方阵槽位互不重合")

	_expect(Formation.slot_offsets(1, Formation.Kind.WEDGE, s).size() == 1, "1 人 → 1 个槽位")
	_expect(Formation.slot_offsets(0, Formation.Kind.WEDGE, s).is_empty(), "0 人 → 空数组")


## 2. 本地偏移 → 世界偏移
func _case_2_to_world() -> void:
	_header("2. 本地→世界变换（队形朝向）")
	var local := Vector3(100.0, 0.0, 0.0)   # 本地右侧 100 m
	# 朝向 -Z 时，右侧是 +X
	var w1 := Formation.to_world(local, Vector3(0.0, 0.0, -1.0))
	_expect(w1.is_equal_approx(Vector3(100.0, 0.0, 0.0)),
		"朝 -Z 时本地 +X → 世界 +X（实际 %s）" % str(w1))
	# 朝向 +X 时，right = forward × up = (1,0,0)×(0,1,0) = (0,0,1)，即世界 +Z
	var w2 := Formation.to_world(local, Vector3(1.0, 0.0, 0.0))
	_expect(w2.is_equal_approx(Vector3(0.0, 0.0, 100.0)),
		"朝 +X 时本地 +X → 世界 +Z（实际 %s）" % str(w2))
	# 本地 z 是"向后"：朝 -Z 时向后就是 +Z
	var w3 := Formation.to_world(Vector3(0.0, 0.0, 100.0), Vector3(0.0, 0.0, -1.0))
	_expect(w3.is_equal_approx(Vector3(0.0, 0.0, 100.0)),
		"朝 -Z 时本地向后 → 世界 +Z（实际 %s）" % str(w3))
	# 零向量必须退化，不能出 NaN
	var w4 := Formation.to_world(local, Vector3.ZERO)
	_expect(w4.is_finite(), "朝向为零向量时不出 NaN（%s）" % str(w4))


# ---------------------------------------------------------------- 用例 3~5：真会战

## 3. 横队：5 艘一起去一个点，到达后沿 X 展开
func _case_3_group_move_line() -> void:
	_header("3. 横队群组移动 → 沿 X 展开")
	var s := _new_session()
	var units := _spawn_group(s, 5)
	_expect(units.size() == 5, "生成 5 艘")
	if units.size() < 5:
		s.shutdown()
		return

	CommandBus.issue(units, BattleSession.CMD_SET_FORMATION, {"formation": Formation.Kind.LINE})
	s.tick(DT)
	_expect(s.formation() == Formation.Kind.LINE, "阵型已切到横队（%s）" % s.formation_name())

	CommandBus.issue(units, BattleSession.CMD_MOVE, {"point": DEST, "source": &"verify"})
	# 命令排队，tick 第 1 步才执行 —— 不跑 tick 就读计数必然是 0
	s.tick(DT)
	_expect(int(s.stats()["formation_slots"]) >= 5,
		"按阵型分配了槽位（%d 次）" % int(s.stats()["formation_slots"]))
	s.tick(DT)

	_run_until_arrived(s, units, ARRIVE_TICKS_MAX)

	var spread := _spread(units)
	_info("  最终队形：X 跨度 %.1f m，Z 跨度 %.1f m，最小间距 %.1f m" % [
		spread.x, spread.z, _min_pair_distance(units)])
	_expect(spread.x > spread.z * 3.0,
		"横队 X 跨度远大于 Z（%.1f vs %.1f）" % [spread.x, spread.z])
	_expect(spread.x > EXPECTED_SPACING * 3.0,
		"确实展开了（X 跨度 %.1f > %.1f）" % [spread.x, EXPECTED_SPACING * 3.0])
	_expect(_min_pair_distance(units) >= MIN_SEPARATION - 1.0,
		"彼此不重叠（最小间距 %.1f ≥ %.1f）" % [
			_min_pair_distance(units), MIN_SEPARATION - 1.0])
	_expect(_slots_occupied(units, DEST, Formation.Kind.LINE, EXPECTED_SPACING, units.size()),
		"每艘船都到了自己的槽位（容差 %.1f m）" % SLOT_TOLERANCE)
	s.shutdown()


## 4. 默认楔形
func _case_4_group_move_wedge() -> void:
	_header("4. 楔形（默认）群组移动 → 两翼展开")
	var s := _new_session()
	var units := _spawn_group(s, 5)
	if units.size() < 5:
		_expect(false, "生成 5 艘")
		s.shutdown()
		return
	_expect(s.formation() == Formation.Kind.WEDGE,
		"默认阵型是楔形（实际 %s）" % s.formation_name())

	CommandBus.issue(units, BattleSession.CMD_MOVE, {"point": DEST, "source": &"verify"})
	_run_until_arrived(s, units, ARRIVE_TICKS_MAX)

	var spread := _spread(units)
	_info("  最终队形：X 跨度 %.1f m，Z 跨度 %.1f m" % [spread.x, spread.z])
	_expect(spread.x > EXPECTED_SPACING * 2.0, "两翼展开（X 跨度 %.1f）" % spread.x)
	_expect(spread.z > 1.0, "有纵深（Z 跨度 %.1f）" % spread.z)
	_expect(_min_pair_distance(units) >= MIN_SEPARATION - 1.0,
		"彼此不重叠（最小间距 %.1f）" % _min_pair_distance(units))
	s.shutdown()


## 5. 途中换阵型：横队 → 纵队，队形必须真的重排
func _case_5_switch_midflight() -> void:
	_header("5. 途中改阵型 → 真的重排（不是只改枚举）")
	var s := _new_session()
	var units := _spawn_group(s, 5)
	if units.size() < 5:
		_expect(false, "生成 5 艘")
		s.shutdown()
		return

	CommandBus.issue(units, BattleSession.CMD_SET_FORMATION, {"formation": Formation.Kind.LINE})
	s.tick(DT)
	CommandBus.issue(units, BattleSession.CMD_MOVE, {"point": DEST, "source": &"verify"})
	# 先飞一段，确保还在途中
	for i in 120:
		s.tick(DT)
	_expect(units[0].has_active_waypoint(), "还在途中（可重排）")

	CommandBus.issue(units, BattleSession.CMD_SET_FORMATION, {"formation": Formation.Kind.COLUMN})
	s.tick(DT)
	_expect(s.formation() == Formation.Kind.COLUMN, "阵型已切到纵队（%s）" % s.formation_name())
	_expect(int(s.stats()["formation_changes"]) >= 2, "换阵型计数已累加")

	_run_until_arrived(s, units, ARRIVE_TICKS_MAX)

	var spread := _spread(units)
	_info("  改阵后：X 跨度 %.1f m，Z 跨度 %.1f m" % [spread.x, spread.z])
	_expect(spread.z > spread.x * 3.0,
		"真的排成纵队了（Z %.1f ≫ X %.1f）" % [spread.z, spread.x])
	_expect(spread.z > EXPECTED_SPACING * 3.0, "纵队纵向展开（Z 跨度 %.1f）" % spread.z)
	_expect(_min_pair_distance(units) >= MIN_SEPARATION - 1.0,
		"彼此不重叠（最小间距 %.1f）" % _min_pair_distance(units))
	s.shutdown()


## 6. 单单位不排阵（不需要为 1 艘船算槽位）
func _case_6_single_unit_no_slot() -> void:
	_header("6. 单单位不分配槽位")
	var s := _new_session()
	var units := _spawn_group(s, 1)
	CommandBus.issue(units, BattleSession.CMD_MOVE, {"point": DEST, "source": &"verify"})
	s.tick(DT)
	_expect(int(s.stats()["formation_slots"]) == 0,
		"单单位没有走阵型分支（槽位 %d）" % int(s.stats()["formation_slots"]))
	_expect(not units[0].route.is_empty(), "但它确实拿到了航线")
	s.shutdown()


## 7. 重复切同阵型幂等
func _case_7_idempotent() -> void:
	_header("7. 重复切同阵型幂等")
	var s := _new_session()
	CommandBus.issue([], BattleSession.CMD_SET_FORMATION, {"formation": Formation.Kind.COLUMN})
	s.tick(DT)
	var before := int(s.stats()["formation_changes"])
	CommandBus.issue([], BattleSession.CMD_SET_FORMATION, {"formation": Formation.Kind.COLUMN})
	s.tick(DT)
	_expect(int(s.stats()["formation_changes"]) == before,
		"重复切同阵型不计数（%d → %d）" % [before, int(s.stats()["formation_changes"])])
	# 越界阵型要钳位，不能把枚举写坏
	CommandBus.issue([], BattleSession.CMD_SET_FORMATION, {"formation": 99})
	s.tick(DT)
	_expect(s.formation() == Formation.KIND_COUNT - 1,
		"越界阵型钳到最后一种（实际 %d）" % s.formation())
	s.shutdown()


## 8. 确定性
func _case_8_determinism() -> void:
	_header("8. 确定性")
	var a := _run_scenario()
	var b := _run_scenario()
	var same := a.size() == b.size()
	if same:
		for i in a.size():
			if not (a[i] as Vector3).is_equal_approx(b[i]):
				same = false
	_expect(same, "两次运行的最终位置逐元素相同（%d 艘）" % a.size())


func _run_scenario() -> Array[Vector3]:
	var s := _new_session()
	var units := _spawn_group(s, 4)
	CommandBus.issue(units, BattleSession.CMD_MOVE, {"point": DEST, "source": &"verify"})
	for i in 600:
		s.tick(DT)
	var out: Array[Vector3] = []
	for unit in s.units():
		out.append(unit.position)
	s.shutdown()
	return out


# ---------------------------------------------------------------- 工具

func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


## 在同一点生成 N 艘同队舰（刻意挤在一起，让阵型负责把它们分开）
func _spawn_group(s: BattleSession, count: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for i in count:
		var u := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
		if u != null:
			out.append(u)
	return out


## 跑到全员到站（或超时）
func _run_until_arrived(s: BattleSession, units: Array[Unit], max_ticks: int) -> int:
	var ticks := 0
	while ticks < max_ticks:
		s.tick(DT)
		ticks += 1
		var all_done := true
		for u in units:
			if u.alive and u.has_active_waypoint():
				all_done = false
				break
		if all_done:
			break
	return ticks


## 相对重心的跨度（X / Z）。返回 Vector3 只为让调用处能直观用 .x / .z
func _spread(units: Array[Unit]) -> Vector3:
	if units.is_empty():
		return Vector3.ZERO
	var c := Vector3.ZERO
	for u in units:
		c += u.position
	c /= float(units.size())
	var sx := 0.0
	var sz := 0.0
	for u in units:
		sx = maxf(sx, absf(u.position.x - c.x))
		sz = maxf(sz, absf(u.position.z - c.z))
	return Vector3(sx * 2.0, 0.0, sz * 2.0)


func _min_pair_distance(units: Array[Unit]) -> float:
	var best := INF
	for i in units.size():
		for j in range(i + 1, units.size()):
			best = minf(best, units[i].position.distance_to(units[j].position))
	return best


## 每个槽位附近是否都有一艘船（不看谁对谁，只看集合是否吻合）
func _slots_occupied(units: Array[Unit], point: Vector3, kind: int,
		spacing: float, count: int) -> bool:
	# 本场景所有单位都从原点生成，所以起点重心 = 原点，朝向就是 DEST 本身。
	# 与 session._assign_formation_routes 的 "point - centroid(当前位置)" 同一口径。
	var forward := point - _start_centroid
	var offsets := Formation.slot_offsets(count, kind, spacing)
	for i in offsets.size():
		var slot := point + Formation.to_world(offsets[i], forward)
		var found := false
		for u in units:
			# 只比水平距离：槽位算在 y=0，船在巡航高度 y=80，垂直差不能计入容差
			if _xz_distance(u.position, slot) <= SLOT_TOLERANCE:
				found = true
				break
		if not found:
			return false
	return true


## 生成组的起点重心（_spawn_group 一律在原点生成）
const _start_centroid := Vector3.ZERO


## 水平（XZ）距离。槽位在水平面内分配，垂直高度归分层系统，不能混算。
func _xz_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _centroid_of(points: Array[Vector3]) -> Vector3:
	var sum := Vector3.ZERO
	for p in points:
		sum += p
	return sum / float(points.size())


func _all_distinct(points: Array[Vector3]) -> bool:
	for i in points.size():
		for j in range(i + 1, points.size()):
			if points[i].distance_to(points[j]) < 0.001:
				return false
	return true


func _max_of(values: PackedFloat32Array) -> float:
	var best := -INF
	for v in values:
		best = maxf(best, v)
	return best


func _min_of(values: PackedFloat32Array) -> float:
	var best := INF
	for v in values:
		best = minf(best, v)
	return best


func _header(text: String) -> void:
	print("[verify_form] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_form] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_form]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_form]   FAIL  %s" % what)
