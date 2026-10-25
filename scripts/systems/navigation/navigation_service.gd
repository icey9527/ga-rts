class_name NavigationService
extends RefCounted

## 寻路对外服务层（ARCHITECTURE「五个核心接口」里的 NavService）。
##
## 职责边界：
##   - 持有障碍表（NavObstacle 数组），给 NavGraph 递一份拷贝就不管了
##   - 计量：请求数 / 节点数 / 耗时 / 超额次数 —— 性能问题必须能被观察，不能靠猜
##   - **时间预算**：单帧最多花多少 usec，超了就让调用方下一帧再来（ADR-0004 要求
##     "分批摊销"，i5-9100F 是 4 核 4 线程，一帧里给 200 个单位同时算路径会卡帧）
##   - 不持有单位状态、不做 CommandBus 仲裁：本类只回答"从 A 到 B 怎么飞"
##
## 为什么预算接口长这样（而不是直接返回一个异步 Promise）：
##   本卡的验收只要求接口与计数，真正异步要等 Simulation 的 tick 有"待办队列"才行（S3）。
##   所以这里只做最保守的两件事：
##     1) reset_frame() 在 tick 开头调用，清空本帧已花时间
##     2) route_or_defer() 在预算已耗尽时**直接返回空数组并把请求计进 deferred**，
##        调用方把请求留到下一帧重发即可 —— 这就是摊销的最小可用形态，
##        将来接上真异步时，替换的是"谁来重发"，不是预算的语义
##   route() 本身永远同步算完（即便超预算），因为验证场景与单测需要确定性结果；
##   两种入口共用同一份计量。
##
## 复杂度：一帧的总耗时 ≈ 本帧请求数 × 单次 NavGraph.solve() 的耗时，
## 单次耗时见 NavGraph 头注释里的 O(N²·K + E log N)。

## 单帧寻路预算（usec）。0.8 ms ≈ 60 fps 一帧 16.6 ms 的 5%，留足了抖动余量。
const DEFAULT_FRAME_BUDGET_USEC := 800

## 障碍表（NavObstacle 引用，不深拷贝：障碍由 terrain 层持有并更新）
var _obstacles: Array = []

## 跨请求复用的求解器（NavGraph.build() 会重置自身状态，复用省掉分配）
var _graph := NavGraph.new()

var _frame_budget_usec := DEFAULT_FRAME_BUDGET_USEC
var _frame_spent_usec := 0

## 统计：请求数 / 延期数 / 节点数与耗时的累加与峰值
var _request_count := 0
var _deferred_count := 0
var _over_budget_count := 0
var _node_total := 0
var _node_max := 0
var _usec_total := 0
var _usec_max := 0
var _last_usec := 0
var _last_node_count := 0
var _last_path_point_count := 0
var _unreachable_count := 0


## 替换障碍表。传进来的数组被浅拷一份，之后调用方怎么改它都不影响本服务。
## 坏元素（null / 非 NavObstacle）在这里就报警：等 NavGraph 里才发现，报错位置会离数据很远。
func set_obstacles(obstacles: Array) -> void:
	_obstacles = []
	for index in obstacles.size():
		var raw: Variant = obstacles[index]
		if raw == null:
			push_error("[NavigationService] 障碍表第 %d 项是 null，跳过" % index)
			continue
		if not (raw is NavObstacle):
			push_error("[NavigationService] 障碍表第 %d 项不是 NavObstacle（实际 %s），跳过" % [
				index, type_string(typeof(raw))])
			continue
		_obstacles.append(raw as NavObstacle)


func obstacles() -> Array:
	return _obstacles.duplicate()


func obstacle_count() -> int:
	return _obstacles.size()


## 同步求一条路径。
## 返回 PackedVector3Array：首点 = 起点（XZ 原样，Y = height，被膨胀圈推过则已推出去），
## 末点 = 终点（同样可能被推出去），中间 = 绕行折点。空数组 = 不可达。
## 时间照实记进统计；是否超预算不影响本函数的结果。
func route(from: Vector3, to: Vector3, unit_radius: float, height: float) -> PackedVector3Array:
	var started := Time.get_ticks_usec()
	_graph.build(_obstacles, from, to, unit_radius, height)
	var path := _graph.solve()
	var elapsed := Time.get_ticks_usec() - started

	_request_count += 1
	_usec_total += elapsed
	_last_usec = elapsed
	_usec_max = maxi(_usec_max, elapsed)
	_frame_spent_usec += elapsed
	if _frame_budget_usec > 0 and elapsed > _frame_budget_usec:
		_over_budget_count += 1
	var nodes := _graph.node_count()
	_node_total += nodes
	_last_node_count = nodes
	_node_max = maxi(_node_max, nodes)
	_last_path_point_count = path.size()
	if path.is_empty():
		_unreachable_count += 1
	return path


## 摊销入口：本帧预算已经花完就直接空手返回（请求计进 deferred，调用方下一帧重发）。
## 这是给 Simulation 的 tick 用的；验证 / 单测走 route()。
## 空数组的语义 = 不可达 / 本次没算，调用方一律按"保持当前航向"处理。
func route_or_defer(from: Vector3, to: Vector3, unit_radius: float, height: float) -> PackedVector3Array:
	if is_frame_exhausted():
		_deferred_count += 1
		return PackedVector3Array()
	return route(from, to, unit_radius, height)


## 单帧预算（usec）。<= 0 表示不限（调试 / 离线烘焙用）。
func set_frame_budget_usec(usec: int) -> void:
	if usec < 0:
		push_error("[NavigationService] 帧预算为负（%d usec），按 0（不限）处理" % usec)
		usec = 0
	_frame_budget_usec = usec


func frame_budget_usec() -> int:
	return _frame_budget_usec


## 每 tick 开头调用（Simulation 的责任），清空本帧已花时间。
func reset_frame() -> void:
	_frame_spent_usec = 0


func frame_spent_usec() -> int:
	return _frame_spent_usec


## 本帧预算是否已经花完。预算 <= 0（不限）时永远返回 false。
func is_frame_exhausted() -> bool:
	if _frame_budget_usec <= 0:
		return false
	return _frame_spent_usec >= _frame_budget_usec


## 统计快照。键名固定，UI / 调试面板 / 验证场景都读这个（不要各自另加计数器）。
func stats() -> Dictionary:
	var requests := _request_count
	return {
		"requests": requests,
		"deferred": _deferred_count,
		"over_budget": _over_budget_count,
		"unreachable": _unreachable_count,
		"nodes_avg": (float(_node_total) / float(requests)) if requests > 0 else 0.0,
		"nodes_max": _node_max,
		"usec_avg": (float(_usec_total) / float(requests)) if requests > 0 else 0.0,
		"usec_max": _usec_max,
		"usec_last": _last_usec,
		"budget_usec": _frame_budget_usec,
		"frame_spent_usec": _frame_spent_usec,
		"last_node_count": _last_node_count,
		"last_path_points": _last_path_point_count,
	}


## 只清计量，不清障碍表与预算设定
func reset_stats() -> void:
	_request_count = 0
	_deferred_count = 0
	_over_budget_count = 0
	_node_total = 0
	_node_max = 0
	_usec_total = 0
	_usec_max = 0
	_last_usec = 0
	_last_node_count = 0
	_last_path_point_count = 0
	_unreachable_count = 0
	_frame_spent_usec = 0


## 上一次请求的节点数（验证 / 调试用）
func last_node_count() -> int:
	return _last_node_count
