extends Node3D

## T-3.1 验收：高度层切换（ADR-0003）。
##
## 切层看起来只是"改一个数"，实际上同时影响三件事，本场景逐条验：
##   1. 层表一致性 —— 三份层定义（模拟/数据/输入）不能各自漂移
##   2. 单位爬升/下降 —— 软回拉把船推到新层的巡航高度，不是瞬移
##   3. 航线合法性 —— 切层后必须重算，否则会出现「绕过已经不挡的岩石」
##      或「直接穿过现在挡路的岩石」
##
## 运行：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path F:/godot/ga-rts \
##       scenes/dev/verify_layer.tscn

const DT := 1.0 / 60.0
const SHIP := "ou05"
const TEAM_BLUE := 0

## L1(0) → L2(+400)：ou05 巡航偏移 +80，要走 480 m；回拉上限 60 m/s ≈ 8 s。给 15 s
const CLIMB_TICKS_MAX := 900
## L2(+480) → L0(-320)：要走 800 m ≈ 13.3 s。给 25 s
const DIVE_TICKS_MAX := 1500

## 绕行用例的几何：半径 300 的柱体，top=200 → L1(0) 挡 / L2(400) 不挡
const OBSTACLE_RADIUS := 300.0
const OBSTACLE_TOP := 200.0
const OBSTACLE_BOTTOM := -300.0
const ROUTE_FROM := Vector3(-800.0, 0.0, 0.0)
const ROUTE_TO := Vector3(800.0, 0.0, 0.0)
## 起终点直线距离 = 1600 m
const STRAIGHT := 1600.0

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame

	print("[verify_layer] ==== T-3.1 高度层切换 ====")
	_case_1_tables_agree()
	_case_2_set_layer_command()
	_case_3_climb()
	_case_4_dive()
	_case_5_repath_on_layer_change()
	_case_6_idempotent()
	_case_7_clamp()

	print("[verify_layer] ---- 结果 ----")
	print("[verify_layer]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_layer] PASS")
		get_tree().quit(0)
	else:
		print("[verify_layer] FAIL")
		get_tree().quit(1)


# ---------------------------------------------------------------- 用例

## 1. 三份层表必须一致。分散定义是漂移的温床，用断言把它们钉在一起。
func _case_1_tables_agree() -> void:
	_header("1. 层表一致性（模拟 / 数据 / 输入三层定义）")
	_expect(BattleSession.LAYER_COUNT == 3, "共 3 层（实际 %d）" % BattleSession.LAYER_COUNT)
	var expected := [-400.0, 0.0, 400.0]
	for i in 3:
		var center := BattleSession.layer_center(i)
		_expect(is_equal_approx(center, expected[i]),
			"L%d 层中心 = %.0f m（实际 %.1f）" % [i, expected[i], center])
		_expect(is_equal_approx(center, InputRouter.ALTITUDE_LAYERS[i]),
			"L%d 与 InputRouter.ALTITUDE_LAYERS 一致（%.1f vs %.1f）" % [
				i, center, InputRouter.ALTITUDE_LAYERS[i]])
		_expect(is_equal_approx(center, float(MapDef.LAYER_CENTERS[i])),
			"L%d 与 MapDef.LAYER_CENTERS 一致（%.1f vs %.1f）" % [
				i, center, float(MapDef.LAYER_CENTERS[i])])


## 2. 切层命令是会话级的：不带 target 也必须生效
func _case_2_set_layer_command() -> void:
	_header("2. cmd_set_layer 是会话级命令（不需要 target）")
	var s := _new_session()
	_expect(s.layer_index() == BattleSession.LAYER_DEFAULT,
		"开局在默认层 L%d" % s.layer_index())

	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 2, "source": &"verify"})
	# 命令是**排队**的：issue() 只入队 + 发信号，session 在 tick 第 1 步才统一执行
	# （硬规则 2：单一更新驱动）。入队后立刻读状态必然是旧值 —— 这是设计，不是 bug。
	_expect(s.layer_index() == 1, "入队瞬间仍是 L1（tick 第 1 步才生效）")
	s.tick(DT)
	_expect(s.layer_index() == 2, "切到 L2（实际 L%d）" % s.layer_index())
	_expect(is_equal_approx(s.layer_height(), 400.0),
		"层中心 = 400 m（实际 %.1f）" % s.layer_height())
	_expect(int(s.stats()["layer_changes"]) == 1, "切层计数 = 1")

	# 不存在的层号也要被钳位，不能把 _layer_height 写坏
	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 99})
	s.tick(DT)
	_expect(s.layer_index() == 2, "越界层号被钳到 2（实际 L%d）" % s.layer_index())
	s.shutdown()


## 3. 爬升：L1 → L2，靠软回拉上去，不是瞬移
func _case_3_climb() -> void:
	_header("3. 爬升 L1(0 m) → L2(+400 m)")
	var s := _new_session()
	var u := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	_expect(u != null, "生成一艘 ou05")
	if u == null:
		s.shutdown()
		return

	var y0 := u.position.y
	var target_l2 := UnitFlight.cruise_target_y(u, BattleSession.layer_center(2))
	_info("  目标高度 %.0f m（层中心 400 + 巡航偏移 %.0f），起点 %.0f m" % [
		target_l2, u.cruise_altitude, y0])

	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 2})
	s.tick(DT)
	# 单 tick 爬升上限 = 60 m/s × 1/60 s = 1.0 m。用 2.0 做阈值（相邻 tick 量级），
	# 既证明没有瞬移，也不因为恰好等于 1.0 而误判。
	var per_tick_max := UnitFlight.MAX_RETURN_SPEED * DT
	_expect(u.position.y <= per_tick_max * 2.0,
		"切层瞬间**没有瞬移**（y = %.2f m，单 tick 上限 %.2f m）" % [u.position.y, per_tick_max])

	var ticks := 0
	var seen_overshoot := false
	while ticks < CLIMB_TICKS_MAX:
		s.tick(DT)
		ticks += 1
		if u.position.y > target_l2 + 1.0:
			seen_overshoot = true
		if UnitFlight.in_band(u, s.layer_height()):
			break

	_info("  用 %d tick（%.1f 秒）爬进容差带，最终 y = %.1f m" % [
		ticks, float(ticks) * DT, u.position.y])
	_expect(UnitFlight.in_band(u, s.layer_height()), "已进入 L2 容差带")
	_expect(u.position.y > y0 + 200.0, "确实爬升了（%.1f → %.1f）" % [y0, u.position.y])
	_expect(absf(u.position.y - target_l2) <= UnitFlight.BAND,
		"停在巡航目标 %.0f ± %.0f m 内（实际 %.1f）" % [
			target_l2, UnitFlight.BAND, u.position.y])
	_expect(not seen_overshoot, "回拉不过冲（软回拉按剩余偏差截断）")

	# 单 tick 位移不能超过回拉上限 —— 证明是"飞"上去的，不是"跳"上去的
	_expect(UnitFlight.MAX_RETURN_SPEED <= 60.0,
		"回拉速度上限 %.0f m/s（小于 60° 爬升的垂直速度，允许主动爬出层）" % UnitFlight.MAX_RETURN_SPEED)
	s.shutdown()


## 4. 下降：L2 → L0
func _case_4_dive() -> void:
	_header("4. 下降 L2(+400 m) → L0(-400 m)")
	var s := _new_session()
	var u := s.spawn_unit(SHIP, Vector3.ZERO, TEAM_BLUE)
	_expect(u != null, "生成一艘 ou05")
	if u == null:
		s.shutdown()
		return

	# 先升到 L2
	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 2})
	for i in CLIMB_TICKS_MAX:
		s.tick(DT)
		if UnitFlight.in_band(u, s.layer_height()):
			break
	var y_high := u.position.y
	_expect(y_high > 300.0, "已在 L2（y = %.1f）" % y_high)

	# 再降到 L0
	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 0})
	s.tick(DT)
	_expect(u.position.y > 200.0, "切到 L0 的瞬间没有瞬移（y = %.1f）" % u.position.y)

	var ticks := 0
	while ticks < DIVE_TICKS_MAX:
		s.tick(DT)
		ticks += 1
		if UnitFlight.in_band(u, s.layer_height()):
			break

	var target_l0 := UnitFlight.cruise_target_y(u, BattleSession.layer_center(0))
	_info("  用 %d tick（%.1f 秒）降到 y = %.1f m（目标 %.0f）" % [
		ticks, float(ticks) * DT, u.position.y, target_l0])
	_expect(UnitFlight.in_band(u, s.layer_height()), "已进入 L0 容差带")
	_expect(u.position.y < y_high - 400.0, "确实下降了（%.1f → %.1f）" % [y_high, u.position.y])
	_expect(u.position.y < 0.0, "L0 的 y 是负的（实际 %.1f）" % u.position.y)
	s.shutdown()


## 5. 切层必须重算航线：
##    低层障碍（top=200）在 L1 挡路 → 绕行；升到 L2 后不挡 → 走直线
func _case_5_repath_on_layer_change() -> void:
	_header("5. 切层后重算航线（绕过已不挡路的岩石）")
	var s := _new_session()

	var obstacle := NavObstacle.new()
	obstacle.setup(Vector3.ZERO, OBSTACLE_RADIUS, OBSTACLE_TOP, OBSTACLE_BOTTOM)
	s.add_obstacle(obstacle)
	_expect(obstacle.blocks_at(0.0), "该障碍在 L1(0 m) 挡路")
	_expect(not obstacle.blocks_at(400.0), "该障碍在 L2(400 m) 不挡路")

	var u := s.spawn_unit(SHIP, ROUTE_FROM, TEAM_BLUE)
	_expect(u != null, "生成一艘 ou05")
	if u == null:
		s.shutdown()
		return

	CommandBus.issue([u], BattleSession.CMD_MOVE, {"point": ROUTE_TO, "source": &"verify"})
	# 命令在 tick 第 1 步生效（硬规则 2），不跑 tick 就永远拿不到航线
	s.tick(DT)
	var len_l1 := _path_length(u.route)
	_info("  L1 路径：%d 点，%.1f m（直线 %.0f m）" % [
		u.route.size(), len_l1, STRAIGHT])
	_expect(u.route.size() >= 3, "L1 下绕行（%d 点 ≥ 3）" % u.route.size())
	_expect(len_l1 > STRAIGHT * 1.02,
		"L1 路径明显长于直线（%.1f > %.1f）" % [len_l1, STRAIGHT * 1.02])

	# 升层 → 自动重算
	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 2})
	s.tick(DT)
	_expect(int(s.stats()["layer_repaths"]) >= 1,
		"切层触发了航线重算（%d 次）" % int(s.stats()["layer_repaths"]))
	var len_l2 := _path_length(u.route)
	_info("  L2 路径：%d 点，%.1f m" % [u.route.size(), len_l2])
	_expect(len_l2 < len_l1, "L2 路径变短（%.1f < %.1f）" % [len_l2, len_l1])
	_expect(absf(len_l2 - STRAIGHT) < STRAIGHT * 0.05,
		"L2 基本是直线（%.1f，误差 < 5%%）" % len_l2)

	# 降回来必须重新绕 —— 证明重算不是"一次性变直"
	CommandBus.issue([], BattleSession.CMD_SET_LAYER, {"layer": 1})
	s.tick(DT)
	var len_back := _path_length(u.route)
	_info("  降回 L1 后：%d 点，%.1f m" % [u.route.size(), len_back])
	_expect(len_back > STRAIGHT * 1.02, "降回 L1 后又开始绕行（%.1f）" % len_back)
	s.shutdown()


## 6. 幂等：切到当前层不应产生任何变化
func _case_6_idempotent() -> void:
	_header("6. 重复切到同一层是幂等的")
	var s := _new_session()
	s.set_layer_index(1)
	var before := int(s.stats()["layer_changes"])
	s.set_layer_index(1)
	s.set_layer_index(1)
	_expect(int(s.stats()["layer_changes"]) == before,
		"重复切同层不计入 layer_changes（%d → %d）" % [before, int(s.stats()["layer_changes"])])
	s.shutdown()


## 7. 越界钳位
func _case_7_clamp() -> void:
	_header("7. 层号越界钳位")
	var s := _new_session()
	s.set_layer_index(-5)
	_expect(s.layer_index() == 0, "负数钳到 L0（实际 L%d）" % s.layer_index())
	_expect(is_equal_approx(s.layer_height(), -400.0), "L0 高度 -400 m")
	s.set_layer_index(99)
	_expect(s.layer_index() == 2, "超界钳到 L2（实际 L%d）" % s.layer_index())
	_expect(is_equal_approx(s.layer_height(), 400.0), "L2 高度 +400 m")
	s.shutdown()


# ---------------------------------------------------------------- 工具

func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += path[i - 1].distance_to(path[i])
	return total


func _header(text: String) -> void:
	print("[verify_layer] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_layer] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_layer]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_layer]   FAIL  %s" % what)
