extends Node3D

## 竖向切片验收场景（S1 的验收测试，开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path F:\godot\ga-rts \
##         scenes/dev/verify_slice.tscn
##     通过 → exit 0    失败 → exit 1
##
## 验收标准（T-1.6）：点选一艘船 → 右键点目标 → 船沿导航绕过障碍抵达；2D/3D 切换后位置一致。
##
## 五个用例：
##   1. 完整链路：2 个障碍挡路 → **左键点选 1 艘船 → 右键点目标**
##      （Input.parse_input_event 构造真实鼠标事件，走 InputRouter → CommandBus）
##      → 跑到抵达。断言：抵达误差 < 10 m；路径点数 ≥ 3；每段与每个膨胀圈穿透量 ≤ 0
##   2. 不可达：目标不可达（单位被障碍围死）→ 单位原地不动、不崩溃
##   3. 视角一致：抵达后 3D → 2D → 3D，world_to_screen(unit.position) 两次 3D 一致 < 0.5 px
##   4. 命令只走 CommandBus：直接改 unit.route 后 tick —— session 不计数、不覆盖外部写入
##   5. 模拟不依赖节点：BattleSession 是 RefCounted，不 add_child 也能 tick 并正确移动
##
## 场景树里只有验收需要的三样东西（见 verify_slice.tscn）：
##   CameraRig（真相机：用例 1 的点击投影 + 用例 3 的 2D/3D 切换）
##   InputRouter（用例 1 的真实输入入口）
## 没有任何模拟节点：Unit / BattleSession 全是 RefCounted，用例 2/4/5 连相机都不碰。
##
## 注入坐标系：headless 下窗口默认 64×64，而 project.godot 的 canvas_items 拉伸会把事件
## 坐标放大后再送进 _unhandled_input。所以本场景先把窗口固定成 content_scale_size 并
## 关掉拉伸（content_scale_mode = DISABLED），让注入坐标 1:1 到达（与 verify_input 同做法）。

## 模拟步长（与 Simulation.TICK_RATE = 60 一致）
const DT := 1.0 / 60.0
## 被测机型逻辑 ID（= content/units 下的目录名，不是路径）
const SHIP_DEF_ID := "ou134"
## 抵达误差上限（米）—— 验收标准
const ARRIVAL_TOLERANCE_M := 10.0
## 路径穿透容差（米）：可视图的弦与膨胀圆相切，只允许浮点噪声
const PATH_PENETRATION_TOLERANCE := 1.0e-3
## 完整链路的最长 tick 数（120 s 模拟时间）
const MAX_CHAIN_TICKS := 7200
## 不可达用例观察的 tick 数（5 s）
const UNREACHABLE_TICKS := 300
## 视角一致性的像素容差
const VIEW_PIXEL_TOLERANCE := 0.5
## 用例 5 的 tick 数与位置判据（米）
const NO_TREE_TICKS := 300
const NO_TREE_MIN_TRAVEL := 300.0
## 用例 1 的点击坐标系（关掉拉伸后的窗口尺寸）
const VIEWPORT_SIZE := Vector2i(1152, 648)
## 右键落点允许的误差（米）：screen_to_world 与投影参考高度都是 0 平面，应几乎精确
const CLICK_POINT_TOLERANCE_M := 0.01
## 用例 1 的机位：够同时看到起点 (-2500) 与目标 (3500)
const CHAIN_CAMERA_DISTANCE := 9000.0
const CHAIN_CAMERA_PITCH_DEG := -45.0

# ---------------------------------------------------------------- 用例 1 场景
#
# 起终点连线（z=0）正好穿过两个障碍的膨胀圈，因此必须绕行。
# 障碍半径 400 → 膨胀 424（单位半径取 TBL/兜底值，不在这里写死）。
const CHAIN_START := Vector3(-2500.0, 0.0, 0.0)
const CHAIN_TARGET := Vector3(3500.0, 0.0, 0.0)
const CHAIN_OBSTACLES := [
	{"position": Vector3(0.0, 0.0, 0.0), "radius_xz": 400.0, "top_y": 600.0, "bottom_y": -400.0},
	{"position": Vector3(1100.0, 0.0, 0.0), "radius_xz": 400.0, "top_y": 600.0, "bottom_y": -400.0},
]

# ---------------------------------------------------------------- 用例 2 场景
const TRAP_OBSTACLE_COUNT := 6
const TRAP_OBSTACLE_RADIUS := 300.0
## 包围圈半径（圆心到原点的距离）。必须同时满足两条，否则用例 2 的题材就失效了：
##   1. 起点（原点）不在任何**膨胀**圈里：R > 障碍 r + 单位 r + 余量
##   2. 相邻膨胀圈互相压过（洞封死）：相邻圆心距 R < 2 × 膨胀半径
## T-2.0 起 SHIP_DEF_ID 的 radius 来自 unit.tbl，ou134 = 176 m（船长 351.7 的一半），
## 膨胀半径 300+176+4 = 480 → R 必须 > 480；原地 400 会让起点落进圈内，
## 单位被推到圈外后直接看得见目标，于是"围死"变成了"能跑出去"。
## 取 R = 700：起点离圆心 700 > 480（在圈外），相邻圆心距 700 < 960（洞封死）。
const TRAP_RING_DISTANCE := 700.0
const TRAP_START := Vector3.ZERO
const TRAP_TARGET := Vector3(5000.0, 0.0, 0.0)

# ---------------------------------------------------------------- 用例 4 场景
const BUS_START := Vector3(-1500.0, 0.0, 0.0)
const BUS_TARGET := Vector3(1500.0, 0.0, 0.0)
## 绕过 CommandBus 直接写进 unit.route 的目标点（与 BUS_TARGET 完全不同方向）
const EXTERNAL_ROUTE_TARGET := Vector3(-1500.0, 0.0, -1200.0)

# ---------------------------------------------------------------- 用例 5 场景
const NO_TREE_START := Vector3.ZERO
const NO_TREE_TARGET := Vector3(0.0, 0.0, -1000.0)

@onready var camera_rig: RtsCameraRig = $CameraRig
@onready var input_router: InputRouter = $InputRouter

## 双视图唯一投影（与 InputRouter 共用 rig.view_projection() 的同一个实例）
var _projection: ViewProjection = null

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	_configure_window()
	# 等一帧：窗口尺寸 / 拉伸设置落地，子节点 _ready 与相机装配也先跑完
	await get_tree().process_frame
	_projection = camera_rig.view_projection()
	input_router.setup(camera_rig, _projection)

	var chain := await _case_1_full_chain()
	_case_2_unreachable()
	await _case_3_view_consistency(chain)
	_case_4_command_only_via_bus()
	_case_5_no_scene_tree()

	_report()


# ---------------------------------------------------------------- 用例 1：完整链路

## 返回 {unit, ticks}；失败时 unit 仍返回（用例 3 需要一个真实单位来投影）
func _case_1_full_chain() -> Dictionary:
	_header("1. 完整链路 —— 左键点选 → 右键点目标 → 绕障碍抵达")
	var session := _new_session()
	var obstacles := _add_obstacles(session, CHAIN_OBSTACLES)
	for obstacle in obstacles:
		_info("障碍 %s（膨胀半径按单位半径算）" % obstacle.describe())

	var unit := session.spawn_unit(SHIP_DEF_ID, CHAIN_START)
	if unit == null:
		_expect(false, "spawn_unit(%s) 成功" % SHIP_DEF_ID)
		session.shutdown()
		return {"unit": null, "ticks": 0}
	_info("生成单位：%s" % unit.describe())
	_info("机型数据来源：%s" % _data_source_text(session))
	_info("TBL 速度 %.3f m/s ↔ Unit.max_speed %.3f m/s（证明没硬编码）" % [
		_registry_speed(SHIP_DEF_ID), unit.max_speed])
	_expect(is_equal_approx(unit.max_speed, _registry_speed(SHIP_DEF_ID)),
		"max_speed 来自 TBL（%0.3f）" % unit.max_speed)
	_expect(unit.radius >= 0.0 and unit.acceleration > 0.0 and unit.deceleration > 0.0,
		"机动参数已装配（accel=%.1f decel=%.1f r=%.1f yaw=%.2f°/s）" % [
			unit.acceleration, unit.deceleration, unit.radius,
			rad_to_deg(unit.turn_rate_yaw)])

	# ── 真实输入链路：左键点选 → 右键点目标 ──────────────────────────────
	# 候选 = Unit 数据对象（ViewProjection 认它的 position 属性），与 battle.tscn 同口径。
	input_router.set_candidates(session.units())
	var camera_focus := CHAIN_START.lerp(CHAIN_TARGET, 0.5)
	camera_rig.focus_on(camera_focus, true)
	camera_rig.camera_3d.zoom_to(CHAIN_CAMERA_DISTANCE, true)
	camera_rig.camera_3d.set_pitch_degrees(CHAIN_CAMERA_PITCH_DEG)
	_projection.set_reference_height(camera_focus.y)
	await get_tree().process_frame
	_expect(camera_rig.mode() == RtsCameraRig.ViewMode.VIEW_3D, "点选前相机处于 3D 模式")

	var screen_unit := _projection.world_to_screen(unit.position)
	var screen_target := _projection.world_to_screen(CHAIN_TARGET)
	_info("投影：船 %s → 屏幕 %s；目标 %s → 屏幕 %s（视口 %s）" % [
		_short(unit.position), str(screen_unit), _short(CHAIN_TARGET), str(screen_target),
		str(_projection.viewport_size())])
	_expect(_projection.is_visible(unit.position) and _projection.is_visible(CHAIN_TARGET),
		"船与目标都在相机前方（可以点）")

	var bus_hits := [0]
	var bus_points: Array = []
	var counter := func(_target: Variant, kind: StringName, options: Dictionary) -> void:
		if kind == BattleSession.CMD_MOVE:
			bus_hits[0] += 1
			bus_points.append(options.get("point", null))
	CommandBus.command_issued.connect(counter)

	await _click(screen_unit, MOUSE_BUTTON_LEFT)
	var selection := GameState.selected_units()
	_expect(selection.size() == 1 and selection[0] == unit,
		"左键点选后 GameState 选中这艘船（实际 %d 个）" % selection.size())
	_expect(input_router.selection().size() == 1, "InputRouter 的选择列表同步")

	await _click(screen_target, MOUSE_BUTTON_RIGHT)
	_info("右键点目标后：CommandBus 收到 cmd_move %d 条，session.stats.commands_received=%d" % [
		bus_hits[0], session.stats()["commands_received"]])
	_expect(bus_hits[0] == 1, "右键点击 → CommandBus 收到 1 条 cmd_move（实际 %d）" % bus_hits[0])
	_expect(session.stats()["commands_received"] == 1,
		"session 通过信号收到 1 条命令（实际 %d）" % session.stats()["commands_received"])
	if bus_points.is_empty() or typeof(bus_points[0]) != TYPE_VECTOR3:
		_expect(false, "命令带有世界落点 point")
	else:
		var command_point: Vector3 = bus_points[0]
		var point_error := command_point.distance_to(CHAIN_TARGET)
		_info("命令落点 %s，与目标差 %.6f m" % [_short(command_point), point_error])
		_expect(point_error < CLICK_POINT_TOLERANCE_M,
			"落点误差 %.6f m < %.2f m" % [point_error, CLICK_POINT_TOLERANCE_M])

	# 第一条 tick 处理命令：装航线
	session.tick(DT)
	_info("首个 tick 后：stats=%s" % str(session.stats()))
	_expect(session.stats()["commands_applied"] == 1, "命令在 tick 第 1 步被处理")
	_expect(session.stats()["routes_assigned"] == 1,
		"算出 1 条可用路径（requests=%d unreachable=%d）" % [
			session.stats()["route_requests"], session.stats()["unreachable"]])
	_info("路径 %d 点：%s" % [unit.route.size(), _path_text(unit.route)])
	_expect(unit.route.size() >= 3, "路径点数 ≥ 3（实际 %d，确实绕行）" % unit.route.size())

	# 跑模拟直到抵达
	var ticks := 1
	while ticks < MAX_CHAIN_TICKS and not unit.is_route_finished():
		session.tick(DT)
		ticks += 1
	var error := unit.position.distance_to(CHAIN_TARGET)
	_info("%d tick（%.2f s）后：位置 %s，速度 %.4f m/s，finished=%s" % [
		ticks, float(ticks) * DT, _short(unit.position), unit.speed, str(unit.is_route_finished())])
	_info("抵达误差 = %.6f m" % error)
	_info("最终 stats=%s" % str(session.stats()))
	_info("寻路计量：%s" % str(session.navigation_stats()))

	_expect(unit.is_route_finished(), "航线走完（finished = true）")
	_expect(error < ARRIVAL_TOLERANCE_M,
		"抵达误差 %.6f m < %.1f m" % [error, ARRIVAL_TOLERANCE_M])
	_expect(session.stats()["arrived"] == 1, "stats.arrived = 1（实际 %d）" % session.stats()["arrived"])
	_expect(session.stats()["active_routes"] == 0,
		"抵达后没有活跃路线（实际 %d）" % session.stats()["active_routes"])
	_expect(bus_hits[0] == 1, "全程只发了 1 条 cmd_move（实际 %d）" % bus_hits[0])

	# 路径不穿模：每一段对每一个膨胀圈
	var worst := _worst_penetration(unit.route, obstacles, unit.radius)
	_info("最坏穿透量 = %+.6f m（正数 = 切进膨胀圈，负数 = 留空；判据 ≤ 0）" % worst)
	for i in range(1, unit.route.size()):
		var parts := PackedStringArray()
		for obstacle in obstacles:
			var inflated := obstacle.inflated_radius(unit.radius)
			var distance := _distance_point_segment(
				Vector2(obstacle.position.x, obstacle.position.z),
				unit.route[i - 1], unit.route[i])
			parts.append("%.3f/%.1f" % [distance, inflated])
		_info("  段 %d：%s → %s  离圆心/膨胀 = %s" % [
			i, _short(unit.route[i - 1]), _short(unit.route[i]), " , ".join(parts)])
	_expect(worst <= PATH_PENETRATION_TOLERANCE,
		"每段穿透量 ≤ 0（最坏 %+.6f m ≤ %+.6f）" % [worst, PATH_PENETRATION_TOLERANCE])

	CommandBus.command_issued.disconnect(counter)
	input_router.set_selection([])
	GameState.set_selected_units([])
	session.shutdown()
	return {"unit": unit, "ticks": ticks}


# ---------------------------------------------------------------- 用例 2：不可达

func _case_2_unreachable() -> void:
	_header("2. 不可达 —— 单位被 %d 个障碍围死，目标在圈外" % TRAP_OBSTACLE_COUNT)
	var session := _new_session()
	var ring: Array = []
	for i in TRAP_OBSTACLE_COUNT:
		var angle := TAU * float(i) / float(TRAP_OBSTACLE_COUNT)
		ring.append({
			"position": Vector3(cos(angle) * TRAP_RING_DISTANCE, 0.0,
				sin(angle) * TRAP_RING_DISTANCE),
			"radius_xz": TRAP_OBSTACLE_RADIUS,
			"top_y": 600.0,
			"bottom_y": -400.0,
		})
	var obstacles := _add_obstacles(session, ring)
	var unit := session.spawn_unit(SHIP_DEF_ID, TRAP_START)
	if unit == null:
		_expect(false, "spawn_unit 成功")
		session.shutdown()
		return

	var inflated := obstacles[0].inflated_radius(unit.radius)
	_info("包围圈：相邻圆心距 %.1f m，膨胀半径 %.1f m（必然重叠）" % [
		2.0 * TRAP_RING_DISTANCE * sin(PI / float(TRAP_OBSTACLE_COUNT)), inflated])
	_info("起点 %s（在包围圈内、不在任何圈里）→ 目标 %s" % [
		_short(TRAP_START), _short(TRAP_TARGET)])

	var start := unit.position
	GameState.set_selected_units([unit])
	CommandBus.issue(GameState.selected_units(), BattleSession.CMD_MOVE,
		{"point": TRAP_TARGET, "source": &"verify"})
	session.tick(DT)
	var after_command := unit.position
	var stats := session.stats()
	_info("首个 tick 后：route=%d 点，unreachable=%d，position %s" % [
		unit.route.size(), stats["unreachable"], _short(after_command)])

	_expect(stats["unreachable"] == 1,
		"记 1 次不可达（实际 %d）" % stats["unreachable"])
	_expect(stats["routes_assigned"] == 0, "没有装上空航线（routes_assigned=%d）" % stats["routes_assigned"])
	_expect(unit.route.is_empty(), "unit.route 为空（实际 %d 点）" % unit.route.size())

	# 再跑 5 s：不崩、不动
	for _i in UNREACHABLE_TICKS:
		session.tick(DT)
	var drift := after_command.distance_to(unit.position)
	var total := start.distance_to(unit.position)
	_info("%d tick 后：位置 %s，首个 tick 后位移 %.9f m，总位移 %.9f m，速度 %.6f m/s" % [
		UNREACHABLE_TICKS, _short(unit.position), drift, total, unit.speed])

	_expect(drift < 1.0e-6, "不可达后原地不动（%.9f m < 1e-6）" % drift)
	_expect(total < 1.0e-6, "从起点算也没漂移（%.9f m）" % total)
	_expect(is_equal_approx(unit.speed, 0.0), "速度保持 0（实际 %.9f m/s）" % unit.speed)
	_expect(session.stats()["units"] == 1, "session 仍健康（units=%d）" % session.stats()["units"])

	GameState.set_selected_units([])
	session.shutdown()


# ---------------------------------------------------------------- 用例 3：2D/3D 一致

func _case_3_view_consistency(chain: Dictionary) -> void:
	_header("3. 2D/3D 切换后位置一致 —— world_to_screen 两次 3D 差 < %.1f px" % VIEW_PIXEL_TOLERANCE)
	var unit: Unit = chain.get("unit", null)
	if unit == null:
		_expect(false, "用例 1 提供了可投影的单位")
		return
	var rig := camera_rig
	var projection := _projection
	_expect(projection != null and projection.is_ready(), "ViewProjection 已就绪")
	# 显式回到 3D 起点，避免用例间耦合（用例 1 的点击不切模式）
	rig.force_mode(RtsCameraRig.ViewMode.VIEW_3D)
	await get_tree().process_frame

	# 机位：焦点放在"起点与抵达点之间"，单位因此落在屏幕**偏心**位置 ——
	# 投影到正中心的话，任何相机都能给出同一个像素，用例就没有意义了。
	var focus_point := unit.position.lerp(CHAIN_START, 0.5)
	rig.focus_on(focus_point, true)
	await get_tree().process_frame
	_expect(rig.mode() == RtsCameraRig.ViewMode.VIEW_3D, "当前是 3D 模式")
	_expect(projection.is_visible(unit.position), "单位在相机前方（投影有效）")
	var focus_before := rig.focus_position()

	var screen_3d_before := projection.world_to_screen(unit.position)
	var mode_before := projection.mode()
	_info("3D：world_to_screen(%s) = (%.6f, %.6f)，projection=%d" % [
		_short(unit.position), screen_3d_before.x, screen_3d_before.y, mode_before])

	rig.toggle_mode()
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(rig.mode() == RtsCameraRig.ViewMode.VIEW_2D, "切到 2D 模式")
	var screen_2d := projection.world_to_screen(unit.position)
	_info("2D：world_to_screen(%s) = (%.6f, %.6f)，projection=%d（正交，镜头不同所以坐标不同）" % [
		_short(unit.position), screen_2d.x, screen_2d.y, projection.mode()])
	_expect(projection.is_orthographic(), "2D 模式下投影是正交")
	_expect(rig.focus_position().distance_to(focus_before) < 1.0,
		"切 2D 后焦点不变（差 %.6f m）" % rig.focus_position().distance_to(focus_before))

	rig.toggle_mode()
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(rig.mode() == RtsCameraRig.ViewMode.VIEW_3D, "切回 3D 模式")

	var screen_3d_after := projection.world_to_screen(unit.position)
	var pixel_delta := screen_3d_before.distance_to(screen_3d_after)
	_info("3D（切回）：world_to_screen(%s) = (%.6f, %.6f)" % [
		_short(unit.position), screen_3d_after.x, screen_3d_after.y])
	_info("两次 3D 的屏幕差 = %.9f px；单位位置未变（链路不带位移）" % pixel_delta)
	_expect(pixel_delta < VIEW_PIXEL_TOLERANCE,
		"两次 3D 投影一致（%.9f px < %.1f px）" % [pixel_delta, VIEW_PIXEL_TOLERANCE])
	_expect(projection.mode() == mode_before, "切回后投影方式与切换前相同")


# ---------------------------------------------------------------- 用例 4：只走 CommandBus

func _case_4_command_only_via_bus() -> void:
	_header("4. 命令只走 CommandBus —— 直接改 route 时 session 不计数、不覆盖")
	var session := _new_session()
	var unit := session.spawn_unit(SHIP_DEF_ID, BUS_START)
	if unit == null:
		_expect(false, "spawn_unit 成功")
		session.shutdown()
		return

	CommandBus.issue([unit], BattleSession.CMD_MOVE, {"point": BUS_TARGET, "source": &"verify"})
	session.tick(DT)
	var via_bus_stats := session.stats()
	_info("经 CommandBus 后：commands_received=%d routes_assigned=%d 路径末点 %s" % [
		via_bus_stats["commands_received"], via_bus_stats["routes_assigned"],
		_short(unit.route[unit.route.size() - 1]) if not unit.route.is_empty() else "(空)"])
	_expect(via_bus_stats["commands_received"] == 1, "session 收到 1 条命令")
	_expect(via_bus_stats["routes_assigned"] == 1, "装上了 CommandBus 给的航线")

	# 绕过 CommandBus 直接写 unit.route（模拟外部越权写入）
	unit.set_route(PackedVector3Array([BUS_START, EXTERNAL_ROUTE_TARGET]))
	var ticks := 1
	while ticks < MAX_CHAIN_TICKS and not unit.is_route_finished():
		session.tick(DT)
		ticks += 1
	var after := session.stats()
	var to_external := unit.position.distance_to(EXTERNAL_ROUTE_TARGET)
	var to_bus_target := unit.position.distance_to(BUS_TARGET)
	_info("直接写 route 后跑 %d tick：位置 %s，到外部目标 %.3f m，到 CommandBus 目标 %.3f m" % [
		ticks, _short(unit.position), to_external, to_bus_target])
	_info("stats：commands_received=%d（仍应为 1） routes_assigned=%d（仍应为 1）" % [
		after["commands_received"], after["routes_assigned"]])

	_expect(after["commands_received"] == 1,
		"session 没有偷读外部写入（commands_received 仍为 %d）" % after["commands_received"])
	_expect(after["routes_assigned"] == 1,
		"session 没有重新算路径覆盖外部 route（routes_assigned 仍为 %d）" % after["routes_assigned"])
	_expect(to_external < ARRIVAL_TOLERANCE_M,
		"移动层按**外部写入**的 route 飞到 %.3f m（证明没有拿缓存路线覆盖）" % to_external)
	_expect(to_bus_target > 1000.0,
		"没有飞回 CommandBus 的目标（距其 %.3f m > 1000）" % to_bus_target)

	session.shutdown()


# ---------------------------------------------------------------- 用例 5：不依赖场景树

func _case_5_no_scene_tree() -> void:
	_header("5. 模拟不依赖节点 —— RefCounted session 不进场景树也能 tick")
	var session := BattleSession.new()
	# 刻意不注入 CommandBus，也不 add_child：模拟层只认显式 tick
	session.setup(GameState.registry(), null)
	# 用 Object 静态类型做 is Node 判定：BattleSession 与 Node 没有继承关系，
	# 直接写 `session is Node` 会被编译器当成不可能表达式拒掉（这本身就是证据）
	var as_object: Object = session
	_info("session 类型：%s（is RefCounted=%s，is Node=%s）" % [
		session.get_class(), str(session is RefCounted), str(as_object is Node)])

	_expect(session is RefCounted, "BattleSession 是 RefCounted")
	_expect(not (as_object is Node), "BattleSession 不是 Node")
	_expect(not session.has_method(&"is_inside_tree"), "没有 is_inside_tree()：它不参与场景树")

	var unit := session.spawn_unit(SHIP_DEF_ID, NO_TREE_START)
	if unit == null:
		_expect(false, "无树状态下 spawn_unit 成功")
		return
	unit.set_route(PackedVector3Array([NO_TREE_START, NO_TREE_TARGET]))
	var start := unit.position

	for _i in NO_TREE_TICKS:
		session.tick(DT)
	var travelled := start.distance_to(unit.position)
	_info("不进树 tick %d 次（%.2f s）：位置 %s，位移 %.3f m，速度 %.3f m/s，stats=%s" % [
		NO_TREE_TICKS, float(NO_TREE_TICKS) * DT, _short(unit.position), travelled,
		unit.speed, str(session.stats())])

	_expect(travelled > NO_TREE_MIN_TRAVEL,
		"位置按 tick 正确推进（位移 %.3f m > %.1f m）" % [travelled, NO_TREE_MIN_TRAVEL])
	_expect(unit.position.z < -NO_TREE_MIN_TRAVEL,
		"朝 -Z 前进（z = %.3f < -%.1f）" % [unit.position.z, NO_TREE_MIN_TRAVEL])
	_expect(absf(unit.position.x) < 1.0 and absf(unit.position.z) > 0.0,
		"没有横移（x = %.6f）" % unit.position.x)
	_expect(session.stats()["ticks"] == NO_TREE_TICKS,
		"tick 计数正确（%d）" % session.stats()["ticks"])
	_expect(not session.navigation_stats().is_empty(), "寻路计量可用（无节点依赖）")
	session.shutdown()


# ---------------------------------------------------------------- 输入注入


## headless 下让注入的鼠标坐标 1:1 到达 _unhandled_input（与 verify_input 同做法）
func _configure_window() -> void:
	var window := get_window()
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	window.content_scale_factor = 1.0
	window.size = VIEWPORT_SIZE
	# 同帧注入的多个事件不得被合并
	Input.use_accumulated_input = false


## 一次点击 = 按下 + 松开（同一帧 flush，中间没有 motion → 位移 0，不会被当成拖拽）
func _click(screen_pos: Vector2, button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	Input.parse_input_event(_button_event(button, true, screen_pos))
	Input.parse_input_event(_button_event(button, false, screen_pos))
	await get_tree().process_frame


func _button_event(index: MouseButton, pressed: bool, screen_pos: Vector2) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = index
	event.pressed = pressed
	event.position = screen_pos
	event.global_position = screen_pos
	return event


# ---------------------------------------------------------------- 工具


func _new_session() -> BattleSession:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	return session


func _add_obstacles(session: BattleSession, defs: Array) -> Array[NavObstacle]:
	var out: Array[NavObstacle] = []
	for def in defs:
		var obstacle := NavObstacle.new(
			def["position"], def["radius_xz"], def["top_y"], def["bottom_y"])
		if not obstacle.is_valid():
			push_error("[verify] 障碍数据不自洽：%s" % obstacle.describe())
			continue
		session.add_obstacle(obstacle)
		out.append(obstacle)
	return out


## TBL 里的 speed（直接从注册表再读一遍，用来证明 Unit 的 max_speed 不是硬编码）
func _registry_speed(def_id: String) -> float:
	var record := GameState.registry().unit(def_id)
	var stats: Dictionary = record.get("stats", {})
	return float(stats.get("speed", -1.0))


func _data_source_text(session: BattleSession) -> String:
	var warnings := session.data_warnings()
	if warnings.is_empty():
		return "全部来自 unit.tbl"
	return "缺键兜底：%s" % str(warnings)


## 所有折线段相对所有膨胀圈的最坏穿透量。
## 单段穿透 = 膨胀半径 − 该段到圆心的最近距离：> 0 表示切进圈内，≤ 0 表示留空。
## 与 verify_nav.gd 同口径（只算 XZ 平面上的点到线段最近距离），但符号按 T-1.6 的验收
## 表述取"穿透量"（越负越安全），因此判据是 **≤ 0**。
func _worst_penetration(route: PackedVector3Array, obstacles: Array[NavObstacle], unit_radius: float) -> float:
	var worst := -INF
	for i in range(1, route.size()):
		for obstacle in obstacles:
			var inflated := obstacle.inflated_radius(unit_radius)
			var distance := _distance_point_segment(
				Vector2(obstacle.position.x, obstacle.position.z), route[i - 1], route[i])
			worst = maxf(worst, inflated - distance)
	return worst


## 点到线段（XZ 平面）的最近距离
func _distance_point_segment(point: Vector2, a: Vector3, b: Vector3) -> float:
	var ax := a.x
	var az := a.z
	var bx := b.x
	var bz := b.z
	var dx := bx - ax
	var dz := bz - az
	var length_squared := dx * dx + dz * dz
	if length_squared <= 1.0e-12:
		return point.distance_to(Vector2(ax, az))
	var t := ((point.x - ax) * dx + (point.y - az) * dz) / length_squared
	t = clampf(t, 0.0, 1.0)
	var closest := Vector2(ax + dx * t, az + dz * t)
	return point.distance_to(closest)


func _path_text(path: PackedVector3Array) -> String:
	if path.is_empty():
		return "(空)"
	var parts := PackedStringArray()
	for point in path:
		parts.append(_short(point))
	return " → ".join(parts)


func _short(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


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
