extends Node3D

## 寻路层验证场景（开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --path F:\godot\ga-rts \
##         scenes/dev/verify_nav.tscn
##     通过 → exit 0    失败 → exit 1
##
## 覆盖 T-1.4 的 8 条验收点（ADR-0004 的算法规格）：
##   1. 无障碍：直线路径，点数 ≤ 2，首尾正确
##   2. 单个障碍挡路：点数 ≥ 3，且每条折线段都不穿透膨胀圈（自己写验证）
##   3. 路径长度合理：绕行总长 < 直线距离 × 1.8
##   4. 高度过滤：单位 y 高于柱顶时该障碍整条剔除，点数 ≤ 2
##   5. 目标落在膨胀圈内：终点被沿径向推到圈外，且离原目标 < 膨胀半径 + 1
##   6. 不可达：起点被完全包围时返回空数组，不崩溃、不死循环
##   7. 性能：50 个障碍、跨障碍长距离，单次 < 5000 usec（实测值全部打印）
##   8. 确定性：同一请求跑两次，结果数组完全一致
##   9.（附加）时间预算摊销接口：route_or_defer 在预算花完后只计数不计算
##
## 本场景**不建任何导航节点**：NavigationService / NavGraph 全是 RefCounted + 纯数学，
## 根节点只是为了能被 `--path ... xxx.tscn` 拉起来。

## 单个障碍用例（用例 2 / 3 / 4 / 5 共用一个障碍）
const OBSTACLE_RADIUS := 300.0
const OBSTACLE_TOP_Y := 200.0
const OBSTACLE_BOTTOM_Y := -200.0
## 单位半径（护卫舰级）
const UNIT_RADIUS := 20.0
## 膨胀后半径 = 300 + 20 + 4（ADR-0004）
const INFLATED_RADIUS := OBSTACLE_RADIUS + UNIT_RADIUS + NavGraph.SAFETY_MARGIN

## 直线距离（from -1000 → to +1000）
const STRAIGHT_DISTANCE := 2000.0
## 绕行长度上限倍率
const MAX_DETOUR_RATIO := 1.8
## 穿透判定的浮点容差（米）：方位节点落在膨胀圆的外切多边形顶点上，
## 相切边到圆心的距离**恰好等于**半径，只允许浮点噪声级别的偏差。
const PENETRATION_TOLERANCE := 0.5
## 用例 5 的容差（米）
const GOAL_PUSH_TOLERANCE := 1.0
## 用例 7：障碍数量 / 战场半宽 / 耗时上限
const PERF_OBSTACLE_COUNT := 50
const PERF_FIELD_HALF := 10000.0
const PERF_MAX_USEC := 5000
## 用例 7：热身 1 次（不进统计）+ 正式测 5 次，取**中位数**判定。
## 单机多任务下 OS 调度就能把单次从 2.8 ms 拖到 7 ms，拿 max 判定会把机器噪声当成回归。
const PERF_REPEAT := 5
## 用例 6：包围圈几何
const TRAP_OBSTACLE_COUNT := 6
const TRAP_OBSTACLE_RADIUS := 300.0
const TRAP_RING_DISTANCE := 400.0

var _failures: Array[String] = []
var _checks := 0

var _service := NavigationService.new()
var _single_obstacle: NavObstacle = null


func _ready() -> void:
	# 等一帧：与其他 dev 场景保持一致的启动节奏（本场景其实不依赖任何节点）
	await get_tree().process_frame

	_single_obstacle = NavObstacle.new(Vector3.ZERO, OBSTACLE_RADIUS, OBSTACLE_TOP_Y, OBSTACLE_BOTTOM_Y)

	_case_1_empty()
	_case_2_single_obstacle()
	_case_3_path_length()
	_case_4_height_filter()
	_case_5_goal_inside_circle()
	_case_6_unreachable()
	_case_7_performance()
	_case_8_determinism()
	_case_9_frame_budget()

	_report()


# ---------------------------------------------------------------- 用例 1：无障碍

func _case_1_empty() -> void:
	_header("1. 无障碍 —— 直线路径")
	_service.reset_stats()
	_service.set_obstacles([])
	var from := Vector3(-1000.0, 0.0, 0.0)
	var to := Vector3(1000.0, 0.0, 0.0)
	var path := _service.route(from, to, UNIT_RADIUS, 0.0)
	_info("障碍 0 个，from=%s to=%s" % [_short(from), _short(to)])
	_info("返回 %d 点：%s" % [path.size(), _path_text(path)])

	_expect(not path.is_empty(), "无障碍时返回非空路径")
	_expect(path.size() <= 2, "点数 ≤ 2（实际 %d）" % path.size())
	if not path.is_empty():
		_expect(path[0].is_equal_approx(from), "首点 == 起点 %s（实际 %s）" % [_short(from), _short(path[0])])
		_expect(path[path.size() - 1].is_equal_approx(to),
			"末点 == 终点 %s（实际 %s）" % [_short(to), _short(path[path.size() - 1])])
		_expect(is_equal_approx(path[0].y, 0.0), "Y 取该层巡航高度（0）")


# ---------------------------------------------------------------- 用例 2：单障碍挡路

func _case_2_single_obstacle() -> void:
	_header("2. 单个障碍挡路 —— 绕行且不穿透膨胀圈")
	_service.reset_stats()
	_service.set_obstacles([_single_obstacle])
	_expect(is_equal_approx(_single_obstacle.inflated_radius(UNIT_RADIUS), INFLATED_RADIUS),
		"膨胀半径 = %0.1f + %0.1f + %0.1f = %0.1f" % [
			OBSTACLE_RADIUS, UNIT_RADIUS, NavGraph.SAFETY_MARGIN, INFLATED_RADIUS])

	var from := Vector3(-1000.0, 0.0, 0.0)
	var to := Vector3(1000.0, 0.0, 0.0)
	var path := _service.route(from, to, UNIT_RADIUS, 0.0)
	_info("返回 %d 点（节点数 %d）：%s" % [path.size(), _service.last_node_count(), _path_text(path)])

	_expect(path.size() >= 3, "点数 ≥ 3（实际 %d）" % path.size())
	_expect(path[0].is_equal_approx(from), "首点是起点")
	_expect(path[path.size() - 1].is_equal_approx(to), "末点是终点")

	var penetration := _worst_penetration(path, [_single_obstacle], UNIT_RADIUS)
	_info("最坏穿透量 = %.6f m（正数=留空，负数=切进圈内；容差 %.2f）" % [
		penetration, PENETRATION_TOLERANCE])
	_expect(penetration >= -PENETRATION_TOLERANCE,
		"每条折线段都不穿透膨胀圈（最坏 %+.6f m ≥ -%.2f）" % [penetration, PENETRATION_TOLERANCE])

	# 单独逐段打印，方便肉眼核对"绕的是哪一侧"
	for i in range(1, path.size()):
		var d := _distance_point_segment(Vector2.ZERO, path[i - 1], path[i])
		_info("  段 %d：%s → %s  离圆心 %.3f m（膨胀半径 %.1f）" % [
			i, _short(path[i - 1]), _short(path[i]), d, INFLATED_RADIUS])


# ---------------------------------------------------------------- 用例 3：路径长度

func _case_3_path_length() -> void:
	_header("3. 路径长度合理 —— 绕行总长 < 直线 × %.1f" % MAX_DETOUR_RATIO)
	var from := Vector3(-1000.0, 0.0, 0.0)
	var to := Vector3(1000.0, 0.0, 0.0)
	var path := _service.route(from, to, UNIT_RADIUS, 0.0)
	var length := _path_length(path)
	var limit := STRAIGHT_DISTANCE * MAX_DETOUR_RATIO
	_info("路径总长 = %.3f m，直线 = %.1f m，比值 = %.4f，上限 = %.1f m" % [
		length, STRAIGHT_DISTANCE, length / STRAIGHT_DISTANCE, limit])
	_info("理论上绕一个半径 %.1f 的圆的最短路径 = 2·√(D²−R²) + R·(π − 2·acos(R/D)) ≈ %.3f m（两段切线 + 弧长），本实现用 12 边形逼近" % [
		INFLATED_RADIUS,
		2.0 * sqrt(1000.0 * 1000.0 - INFLATED_RADIUS * INFLATED_RADIUS)
			+ INFLATED_RADIUS * (PI - 2.0 * acos(INFLATED_RADIUS / 1000.0))])
	_expect(length < limit, "总长 %.3f m < %.1f m" % [length, limit])
	_expect(length > STRAIGHT_DISTANCE, "总长 %.3f m > 直线 %.1f m（确实绕了）" % [
		length, STRAIGHT_DISTANCE])


# ---------------------------------------------------------------- 用例 4：高度过滤

func _case_4_height_filter() -> void:
	_header("4. 高度过滤 —— 单位 y 高于柱顶时障碍整条剔除")
	var from := Vector3(-1000.0, 0.0, 0.0)
	var to := Vector3(1000.0, 0.0, 0.0)

	# 先用 NavGraph 直接看"活着"的障碍数（服务层不暴露内部计数，图是纯 RefCounted，可单测）
	var graph_low := NavGraph.new()
	graph_low.build([_single_obstacle], from, to, UNIT_RADIUS, 0.0)
	var graph_high := NavGraph.new()
	graph_high.build([_single_obstacle], from, to, UNIT_RADIUS, 400.0)
	_info("柱顶 %.1f；高度 0 → 活跃障碍 %d 个，高度 400 → 活跃障碍 %d 个" % [
		OBSTACLE_TOP_Y, graph_low.active_obstacle_count(), graph_high.active_obstacle_count()])
	_expect(graph_low.active_obstacle_count() == 1, "高度 0（L1）时障碍参与寻路")
	_expect(graph_high.active_obstacle_count() == 0, "高度 400（L2）高于柱顶 → 障碍被剔除")

	var path_high := _service.route(from, to, UNIT_RADIUS, 400.0)
	_info("高度 400 返回 %d 点：%s" % [path_high.size(), _path_text(path_high)])
	_expect(path_high.size() <= 2, "高度 400 时点数 ≤ 2（实际 %d，没有绕行点）" % path_high.size())
	_expect(path_high.size() >= 2 and is_equal_approx(path_high[0].y, 400.0),
		"高度 400 的路径 Y = 400（该层巡航高度）")

	# 对照组：同一障碍在 L0（-400）也必须挡路（柱底 -200 以上才算挡，所以 -400 其实能飞过去）
	var path_low := _service.route(from, to, UNIT_RADIUS, -400.0)
	_info("高度 -400（L0，低于柱底 %.1f）返回 %d 点：%s" % [
		OBSTACLE_BOTTOM_Y, path_low.size(), _path_text(path_low)])
	_expect(path_low.size() <= 2, "高度 -400 低于柱底 → 也不挡路（点数 %d ≤ 2）" % path_low.size())


# ---------------------------------------------------------------- 用例 5：目标在膨胀圈内

func _case_5_goal_inside_circle() -> void:
	_header("5. 目标落在膨胀圈内 —— 沿径向推到圈外")
	var from := Vector3(-1000.0, 0.0, 0.0)
	var inside_goal := Vector3(100.0, 0.0, 0.0)

	var graph := NavGraph.new()
	graph.build([_single_obstacle], from, inside_goal, UNIT_RADIUS, 0.0)
	var clamped := graph.goal_point()
	_info("原目标 %s（离圆心 100.0 m < 膨胀半径 %.1f）→ 钳位后 %s" % [
		_short(inside_goal), INFLATED_RADIUS, _short(clamped)])
	_expect(graph.goal_pushed_out(), "NavGraph 报告终点被推出去过")
	_expect(is_equal_approx(clamped.y, 0.0), "推出后 Y 仍是该层巡航高度")

	var path := _service.route(from, inside_goal, UNIT_RADIUS, 0.0)
	var reached := path[path.size() - 1] if not path.is_empty() else Vector3.INF
	var shift := Vector3(inside_goal.x - reached.x, 0.0, inside_goal.z - reached.z).length()
	var from_center := Vector2(reached.x, reached.z).length()
	_info("返回 %d 点，末点 %s：离原目标 %.3f m（上限 %.1f），离圆心 %.3f m（= 膨胀半径）" % [
		path.size(), _short(reached), shift, INFLATED_RADIUS + GOAL_PUSH_TOLERANCE, from_center])

	_expect(not path.is_empty(), "返回非空路径")
	_expect(shift < INFLATED_RADIUS + GOAL_PUSH_TOLERANCE,
		"末点离原目标 %.3f m < 膨胀半径 + %.0f = %.1f" % [
			shift, GOAL_PUSH_TOLERANCE, INFLATED_RADIUS + GOAL_PUSH_TOLERANCE])
	_expect(from_center >= INFLATED_RADIUS - PENETRATION_TOLERANCE,
		"末点已经在膨胀圈外（离圆心 %.3f m ≥ %.1f）" % [from_center, INFLATED_RADIUS])
	var penetration := _worst_penetration(path, [_single_obstacle], UNIT_RADIUS)
	_expect(penetration >= -PENETRATION_TOLERANCE,
		"钳位后的路径同样不穿透（最坏 %+.6f m）" % penetration)


# ---------------------------------------------------------------- 用例 6：不可达

func _case_6_unreachable() -> void:
	_header("6. 不可达 —— 起点被 %d 个障碍围死" % TRAP_OBSTACLE_COUNT)
	var pocket: Array = []
	for i in TRAP_OBSTACLE_COUNT:
		var angle := TAU * float(i) / float(TRAP_OBSTACLE_COUNT)
		pocket.append(NavObstacle.new(
			Vector3(cos(angle) * TRAP_RING_DISTANCE, 0.0, sin(angle) * TRAP_RING_DISTANCE),
			TRAP_OBSTACLE_RADIUS, OBSTACLE_TOP_Y, OBSTACLE_BOTTOM_Y))
	_info("障碍圆心间距 %.1f m，膨胀半径 %.1f m（= %.0f + %.0f + %.0f，相邻两圈必然重叠）" % [
		2.0 * TRAP_RING_DISTANCE * sin(PI / float(TRAP_OBSTACLE_COUNT)),
		TRAP_OBSTACLE_RADIUS + UNIT_RADIUS + NavGraph.SAFETY_MARGIN,
		TRAP_OBSTACLE_RADIUS, UNIT_RADIUS, NavGraph.SAFETY_MARGIN])

	_service.reset_stats()
	_service.set_obstacles(pocket)
	var from := Vector3.ZERO
	var to := Vector3(5000.0, 0.0, 0.0)
	var started := Time.get_ticks_usec()
	var path := _service.route(from, to, UNIT_RADIUS, 0.0)
	var elapsed := Time.get_ticks_usec() - started
	_info("起点 %s（在包围圈内但不在任何圈内）→ 目标 %s" % [_short(from), _short(to)])
	_info("返回 %d 点，耗时 %d usec，尝试次数（服务内部图的重试）见统计" % [path.size(), elapsed])

	_expect(path.is_empty() or path.size() <= 1,
		"不可达时返回空数组或仅起点（实际 %d 点）" % path.size())
	_expect(elapsed < PERF_MAX_USEC,
		"没有死循环：耗时 %d usec < %d usec" % [elapsed, PERF_MAX_USEC])

	# 对照组：同样的包围，把目标放到圈内 → 必须能找到路（否则是"一律返回空"的假通过）
	_service.set_obstacles(pocket)
	var inside_path := _service.route(Vector3.ZERO, Vector3(60.0, 0.0, 0.0), UNIT_RADIUS, 0.0)
	_info("对照组：目标就在身边（1 m 内可直达）→ 返回 %d 点" % inside_path.size())
	_expect(not inside_path.is_empty(), "对照组：身边的目标仍然可达（不是一律返回空）")


# ---------------------------------------------------------------- 用例 7：性能

func _case_7_performance() -> void:
	_header("7. 性能 —— %d 个障碍，跨障碍长距离" % PERF_OBSTACLE_COUNT)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260214
	var obstacles: Array = []
	for i in PERF_OBSTACLE_COUNT:
		obstacles.append(NavObstacle.new(
			Vector3(rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF), 0.0,
				rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF)),
			rng.randf_range(100.0, 600.0), 400.0, -400.0))

	_service.reset_stats()
	_service.set_obstacles(obstacles)
	var from := Vector3(-9000.0, 0.0, 0.0)
	var to := Vector3(9000.0, 0.0, 0.0)

	var worst := 0
	var path := PackedVector3Array()
	# 热身一次（首次请求会付一次性的引擎缓存代价，不能算进“单次耗时”）
	_service.route(from, to, UNIT_RADIUS, 0.0)
	_service.reset_stats()
	var samples := PackedInt32Array()
	for run in PERF_REPEAT:
		var started := Time.get_ticks_usec()
		path = _service.route(from, to, UNIT_RADIUS, 0.0)
		var elapsed := Time.get_ticks_usec() - started
		samples.append(elapsed)
		worst = maxi(worst, elapsed)
		_info("第 %d 次：%d usec（节点 %d，路径 %d 点）" % [
			run + 1, elapsed, _service.last_node_count(), path.size()])
	var median := _median_of(samples)
	var best := samples[0]
	for sample in samples:
		best = mini(best, sample)
	_info("中位数 = %d usec，最小 = %d，最大 = %d（上限 %d）" % [
		median, best, worst, PERF_MAX_USEC])

	var stats := _service.stats()
	_info("路径总长 %.1f m（直线 %.1f m，比值 %.3f）" % [
		_path_length(path), _distance_xz(from, to), _path_length(path) / _distance_xz(from, to)])
	_info("统计：%s" % str(stats))

	# 分区规模的诊断（额外跑一次图，不参与上面的计时）
	var graph := NavGraph.new()
	graph.build(obstacles, from, to, UNIT_RADIUS, 0.0)
	graph.solve()
	_info("分区规模：%d 个障碍在高度 0 活着 → 走廊内生成节点 %d 个 / 参与边测试 %d 个 / 因上限舍掉 %d 个；" % [
		graph.active_obstacle_count(), graph.selected_obstacle_count(),
		graph.edge_obstacle_count(), graph.truncated_obstacle_count()])
	_info("          节点 %d 个、边 %d 条、尝试 %d 次" % [
		graph.node_count(), graph.edge_count(), graph.attempts()])

	_expect(not path.is_empty(), "50 障碍里确实找到了一条绕行路径（%d 点）" % path.size())
	_expect(median < PERF_MAX_USEC,
		"单次中位数 %d usec < %d usec（最大 %d）" % [median, PERF_MAX_USEC, worst])
	var penetration := _worst_penetration(path, obstacles, UNIT_RADIUS)
	_expect(penetration >= -PENETRATION_TOLERANCE,
		"50 障碍的绕行路径同样不穿透任何膨胀圈（最坏 %+.6f m）" % penetration)


# ---------------------------------------------------------------- 用例 8：确定性

func _case_8_determinism() -> void:
	_header("8. 确定性 —— 同一请求跑两次，结果完全一致")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260214
	var obstacles: Array = []
	for i in PERF_OBSTACLE_COUNT:
		obstacles.append(NavObstacle.new(
			Vector3(rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF), 0.0,
				rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF)),
			rng.randf_range(100.0, 600.0), 400.0, -400.0))
	_service.set_obstacles(obstacles)

	var from := Vector3(-9000.0, 0.0, 0.0)
	var to := Vector3(9000.0, 0.0, 0.0)
	var first := _service.route(from, to, UNIT_RADIUS, 0.0)
	var first_nodes := _service.last_node_count()
	var second := _service.route(from, to, UNIT_RADIUS, 0.0)
	var second_nodes := _service.last_node_count()
	_info("第 1 次：%d 点 / 节点 %d；第 2 次：%d 点 / 节点 %d" % [
		first.size(), first_nodes, second.size(), second_nodes])

	_expect(first.size() == second.size(), "两次点数相同（%d vs %d）" % [first.size(), second.size()])
	_expect(first_nodes == second_nodes, "两次节点数相同（%d vs %d）" % [first_nodes, second_nodes])
	var identical := first.size() == second.size()
	if identical:
		for i in first.size():
			if first[i] != second[i]:
				identical = false
				_info("  第 %d 点不一致：%s vs %s" % [i, _short(first[i]), _short(second[i])])
				break
	_expect(identical, "两次返回的 PackedVector3Array 逐元素完全相等")

	# 再来一个"目标被钳位 + 需要绕行"的组合，确保确定性不依赖某一条代码路径
	var inside_goal := Vector3(100.0, 0.0, 0.0)
	_service.set_obstacles([_single_obstacle])
	var a := _service.route(Vector3(-1000.0, 0.0, 0.0), inside_goal, UNIT_RADIUS, 0.0)
	var b := _service.route(Vector3(-1000.0, 0.0, 0.0), inside_goal, UNIT_RADIUS, 0.0)
	_info("钳位用例：第 1 次 %d 点，第 2 次 %d 点" % [a.size(), b.size()])
	_expect(a == b, "钳位 + 绕行的组合同样完全一致")


# ---------------------------------------------------------------- 用例 9：时间预算

## 附加用例：时间预算摊销接口。本卡不做真异步，只保证
##   1) 预算语义可配、可查
##   2) 预算花完后 route_or_defer 只计数不计算（不阻塞、不卡帧）
##   3) reset_frame 之后又能正常算
func _case_9_frame_budget() -> void:
	_header("9.（附加）时间预算摊销 —— 预算花完只计数不计算")
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260214
	var obstacles: Array = []
	for i in PERF_OBSTACLE_COUNT:
		obstacles.append(NavObstacle.new(
			Vector3(rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF), 0.0,
				rng.randf_range(-PERF_FIELD_HALF, PERF_FIELD_HALF)),
			rng.randf_range(100.0, 600.0), 400.0, -400.0))
	_service.set_obstacles(obstacles)
	_service.set_frame_budget_usec(1000)
	_service.reset_stats()
	_service.reset_frame()
	_info("预算 = %d usec / 帧" % _service.frame_budget_usec())

	var from := Vector3(-9000.0, 0.0, 0.0)
	var to := Vector3(9000.0, 0.0, 0.0)
	var computed := 0
	var deferred := 0
	for i in 5:
		var exhausted_before := _service.is_frame_exhausted()
		var path := _service.route_or_defer(from, to, UNIT_RADIUS, 0.0)
		if path.is_empty():
			deferred += 1
		else:
			computed += 1
		_info("  第 %d 次：预算已耗尽=%s → 返回 %d 点（本帧已花 %d usec）" % [
			i + 1, str(exhausted_before), path.size(), _service.frame_spent_usec()])

	var stats := _service.stats()
	_info("统计：%s" % str(stats))
	_expect(computed == 1, "预算 1000 usec 只够算 1 次（实际算了 %d 次）" % computed)
	_expect(deferred == 4, "其余 4 次被延期而不是阻塞（实际 %d 次）" % deferred)
	_expect(int(stats["deferred"]) == 4, "stats.deferred = 4")
	_expect(int(stats["requests"]) == 1, "stats.requests = 1（延期的请求不算计算）")

	# 下一帧：reset_frame 后又可以算一次
	_service.reset_frame()
	_expect(not _service.is_frame_exhausted(), "reset_frame 之后预算重新可用")
	var again := _service.route_or_defer(from, to, UNIT_RADIUS, 0.0)
	_info("reset_frame 后再次请求 → 返回 %d 点" % again.size())
	_expect(not again.is_empty(), "新的一帧能正常算出路径")
	_service.set_frame_budget_usec(NavigationService.DEFAULT_FRAME_BUDGET_USEC)


# ---------------------------------------------------------------- 几何验证工具


## 路径上最坏的一次"穿透量"：对所有折线段、所有膨胀圈取 min(离圆心距离 - 膨胀半径)。
## 正数 = 留了空隙，0 = 精确相切，负数 = 切进圈内（必须 ≥ -PENETRATION_TOLERANCE）。
func _worst_penetration(path: PackedVector3Array, obstacles: Array, unit_radius: float) -> float:
	var worst := INF
	for i in range(1, path.size()):
		for raw in obstacles:
			var obstacle := raw as NavObstacle
			var radius := obstacle.inflated_radius(unit_radius, NavGraph.SAFETY_MARGIN)
			var center := Vector2(obstacle.position.x, obstacle.position.z)
			var d := _distance_point_segment(center, path[i - 1], path[i])
			worst = minf(worst, d - radius)
	return worst


## 点到线段（XZ 平面）的距离
func _distance_point_segment(center: Vector2, a: Vector3, b: Vector3) -> float:
	var ax := a.x
	var az := a.z
	var dx := b.x - ax
	var dz := b.z - az
	var length_squared := dx * dx + dz * dz
	if length_squared <= 0.0:
		return center.distance_to(Vector2(ax, az))
	var t := ((center.x - ax) * dx + (center.y - az) * dz) / length_squared
	t = clampf(t, 0.0, 1.0)
	return center.distance_to(Vector2(ax + dx * t, az + dz * t))


func _path_length(path: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		total += _distance_xz(path[i - 1], path[i])
	return total


## 样本中位数（小样本、不排序，直接算第 k 小，避免再引一个排序工具）
func _median_of(samples: PackedInt32Array) -> int:
	var sorted := samples.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2]


func _distance_xz(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)


# ---------------------------------------------------------------- 输出工具


func _short(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _path_text(path: PackedVector3Array) -> String:
	if path.is_empty():
		return "(空)"
	var parts := PackedStringArray()
	for point in path:
		parts.append(_short(point))
	return " → ".join(parts)


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
