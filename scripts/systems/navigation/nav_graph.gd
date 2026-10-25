class_name NavGraph
extends RefCounted

## XZ 平面「可视图 + Dijkstra」寻路图（ADR-0004）。纯数学，不依赖场景节点。
##
## 一次请求的生命周期：
##   build(obstacles, from, to, unit_radius, height)  —— 准备：高度过滤 / 膨胀 / 起终点推出圈外 /
##                                                      直线可见的快速路径
##   solve()                                          —— 构图 + Dijkstra（结果缓存，可重复调用）
##
## 步骤（与 ADR-0004「实现要点」一一对应）：
##   1. 高度过滤：blocks_at(height) 为 false 的障碍整条从障碍表剔除（= 原 2D 版的 z 过滤）
##   2. 膨胀：r = radius_xz + unit_radius + 4
##   3. 起点 / 终点落在膨胀圈内 → 沿径向推到圈外（迭代，处理互相重叠的圈）
##   4. 直线可见（线段-圆相交测试全过）→ 直接两点路径，不建图
##   5. 否则：每个障碍圈撒 12 个方位节点
##   6. 边 = 两点连线不与任何膨胀障碍相交
##   7. Dijkstra（二叉堆）求最短折线，Y 统一取该层巡航高度 height
##
## 复杂度（K = 参与构图的障碍数，N = 2 + 12·K 节点，E ≤ N(N-1)/2 边）：
##   选障碍 + 起终点钳位   O(M)          M = 高度过滤后的障碍总数
##   节点生成              O(12·K·K)     （每个候选节点要查一遍"是否落在别人的圈里"）
##   边测试                O(N² · K)     （AABB 早退把 K 的常数压到一个很低的量级）
##   Dijkstra              O(E log N)
##   实测：50 个障碍 / 18 km 长距离单次 ~3 ms（本卡验证场景用例 7 打印实测值）。
##
## 走廊分区（ADR-0004 允许"设障碍数量上限或分区"）：
##   只有与直段 from→to 的距离不超过 band 的障碍才生成节点，边测试范围再放宽一圈。
##   几何依据：带内节点的离轴距离上界是 band + r·(1 + 1/cos15°)；两个带内节点之间的
##   线段仍落在同一个凸带里（带是凸的），所以更远的障碍不可能与任何边相交 —— 剔除是
##   安全的，路径不会穿模。band 不够（必须绕开一长串障碍才通）时自动加倍重试，最多
##   MAX_BAND_ATTEMPTS 次；重试没有任何新增障碍时提前收手，不会死循环。
##   代价：极少数情况下路径不是**全局**最短（放弃了一条更远的绕行捷径），
##   这是拿最优性换 O(N²·K) 的常数，ADR-0004 明确许可。
##   障碍极密（碎带）时再加一道闸：节点障碍最多 MAX_NODE_OBSTACLES 个（按离直段远近取舍），
##   被舍掉的圈仍然参加边测试，所以只会退化成"找不到路"，不会穿模。
##
## 性能注意（GDScript 特有）：
##   内层循环一律把成员数组先拷进**局部变量**再跑。成员访问在 GDScript 里是每次
##   一次对象属性查找，边测试那种 O(N²·K) 的循环里这一项能占掉一半时间（实测 8.5 ms
##   → 3 ms）。二叉堆也一并内联进 _dijkstra()。
##
## 本类刻意不做：
##   - 不持有障碍表（由 NavigationService 管，本类只读一份拷贝的数值）
##   - 不做分帧摊销（服务层的事，本类是一次同步求解）
##   - 不画调试线（表现层读 route() 结果自己画）

## 每个障碍圈的方位节点数（ADR-0004 写死 12）
const RING_SAMPLES := 12

## 外切正 12 边形的 外接半径 / 内切半径 = 1 / cos(180°/12) = 1 / cos(15°)。
## 让方位节点落在"外切多边形"的顶点上：相邻两节点之间的弦**与膨胀圆相切**，
## 于是贴边绕行的路径不会切进膨胀圈（用内接多边形就会切进去 r·(1-cos15°) ≈ 3.4%）。
const RING_RADIUS_SCALE := 1.035276180410083

## 膨胀安全余量（ADR-0004：障碍 r + 单位 r + 4）
const SAFETY_MARGIN := 4.0
## 默认走廊半宽（米）：允许绕行偏离直线多远。不够时按 BAND_GROWTH 加倍重试。
const CORRIDOR_BAND := 500.0
## 走廊加宽的最大尝试次数（含第一次），防止病态数据把耗时拖爆
const MAX_BAND_ATTEMPTS := 4
## 每次重试走廊加宽的倍率
const BAND_GROWTH := 2.0
## 走廊里最多给多少个障碍生成节点（ADR-0004 允许的“障碍数量上限”）。
## 10 个 × 12 方位 + 2 = 122 节点 / ≈7.4k 对，单次约 10 ms 的上限；
## 再多就只用“分区”而不给节点，否则碎带一次请求就能卡住整帧。
## 被舍掉的障碍**仍然参加边测试**，所以路径不会穿模：它只会退化成“找不到路”，
## 由调用方（单位）回退到直飞，不会静默穿模。
const MAX_NODE_OBSTACLES := 10
## 起终点被圈包住时的最大推出迭代次数（互相重叠的圈最多推这么多层）
const CLAMP_ITERATIONS := 8
## 几何比较容差（米）：相切算作不穿透
const GEOMETRY_EPSILON := 1.0e-3
## Dijkstra 的"无穷远"
const INFINITE := 1.0e30
## 视觉与统计用的浮点噪声阈值
const MIN_SEGMENT_LENGTH := 1.0e-4


# ---------------------------------------------------------------- 请求状态

var _height := 0.0
var _unit_radius := 0.0
var _start := Vector3.ZERO
var _goal := Vector3.ZERO
var _start_pushed := false
var _goal_pushed := false
var _ready := false
var _solved := false
var _direct := false
var _attempts := 0
var _solution := PackedVector3Array()
var _node_count := 0

## 高度过滤后的障碍（膨胀后半径），平行数组 —— 内层循环里按 float 读取比对象便宜
var _cx := PackedFloat64Array()
var _cz := PackedFloat64Array()
var _cr := PackedFloat64Array()
var _obs_total := 0

## 本次尝试：生成节点的障碍（活跃障碍下标，按到直段的距离升序）
var _sel := PackedInt32Array()
var _sel_count := 0
var _sel_max_radius := 0.0
## 因为 MAX_NODE_OBSTACLES 上限而被舍掉节点生成的障碍数（> 0 表示退化了，要能看见）
var _truncated_count := 0

## 本次尝试：边测试用到的障碍圈（活跃障碍下标的拷贝 + 反查表）
var _ex := PackedFloat64Array()
var _ez := PackedFloat64Array()
var _er := PackedFloat64Array()
var _edge_of_active := PackedInt32Array()

## 节点平行数组
var _nx := PackedFloat64Array()
var _nz := PackedFloat64Array()
## 节点所属障碍（_ex 下标；起点 / 终点为 -1）
var _nobs := PackedInt32Array()
## 节点在 12 个方位槽里的槽号（起点 / 终点为 -1）
var _nslot := PackedInt32Array()

## 边（成对存储：i→j 与 j→i 各一条，构图阶段先平铺，再计数排序成 CSR）
var _edge_from := PackedInt32Array()
var _edge_to := PackedInt32Array()
var _edge_weight := PackedFloat64Array()

## CSR 邻接表
var _adj_start := PackedInt32Array()
var _adj_to := PackedInt32Array()
var _adj_weight := PackedFloat64Array()


# ---------------------------------------------------------------- 对外接口


## 准备一次寻路请求。不建图，只做过滤 + 钳位 + 直线可见的快速路径。
##
## obstacles 的元素必须是 NavObstacle；坏元素（null / 类型不对 / 数据不自洽）跳过并 push_error，
## 不静默忽略 —— 障碍表错了应该在验证场景里立刻炸出来，而不是让飞船事后穿模。
func build(obstacles: Array, from: Vector3, to: Vector3, unit_radius: float, height: float) -> void:
	_reset()
	_height = height
	if unit_radius < 0.0:
		push_error("[NavGraph] unit_radius 为负（%f），按 0 处理" % unit_radius)
		unit_radius = 0.0
	_unit_radius = unit_radius
	if not from.is_finite() or not to.is_finite():
		push_error("[NavGraph] 起终点不是有限数（from=%s to=%s），本次请求不建图" % [
			str(from), str(to)])
		return

	_collect(obstacles)
	_start = _clamp_point(from)
	_goal = _clamp_point(to)
	_start_pushed = not _same_xz(_start, from)
	_goal_pushed = not _same_xz(_goal, to)

	# 快速路径：没有障碍，或直线可视 → 不建图
	if _obs_total == 0 or not _segment_blocked_all(_start.x, _start.z, _goal.x, _goal.z):
		_direct = true
		_node_count = 2
		if _x_z_distance(_start, _goal) <= MIN_SEGMENT_LENGTH:
			_solution = PackedVector3Array([_goal])
		else:
			_solution = PackedVector3Array([_start, _goal])
		_solved = true
	_ready = true


## 求解并返回折线。已求过则直接返回缓存（幂等）。
## 空数组 = 不可达（调用方必须按"原地不动"处理，不要当成"瞬移到原地"）。
func solve() -> PackedVector3Array:
	if not _ready:
		push_error("[NavGraph] solve() 在 build() 之前调用，返回空路径")
		return PackedVector3Array()
	if _solved:
		return _solution

	var band := CORRIDOR_BAND
	var previous_selected := -1
	for attempt in MAX_BAND_ATTEMPTS:
		_attempts = attempt + 1
		if _attempt(band):
			_solved = true
			return _solution
		# 走廊加宽没有引入任何新障碍 → 再加宽也不会有别的结果，提前收手
		if _sel_count <= previous_selected or _sel_count >= _obs_total:
			break
		previous_selected = _sel_count
		band *= BAND_GROWTH

	_solved = true
	_solution = PackedVector3Array()
	return _solution


## 最近一次尝试的节点数（起点 + 终点 + 方位节点）。直线快路径时为 2。
func node_count() -> int:
	return _node_count


## 起点 / 终点（已推出圈外的版本）。测试与调试绘制用。
func start_point() -> Vector3:
	return _start


func goal_point() -> Vector3:
	return _goal


## 起点 / 终点是否被膨胀圈推过（验证用例 5 看得就是这条）
func start_pushed_out() -> bool:
	return _start_pushed


func goal_pushed_out() -> bool:
	return _goal_pushed


## 是否走了"直线可见"的快速路径（没建图）
func is_direct() -> bool:
	return _direct


## 实际尝试了几次（1 = 一次就通了；>1 = 走廊加宽过）
func attempts() -> int:
	return _attempts


## 高度过滤之后仍然"活着"的障碍数
func active_obstacle_count() -> int:
	return _obs_total


## 本次建图实际参与的障碍数（走廊分区之后）/ 边测试范围
func selected_obstacle_count() -> int:
	return _sel_count


func edge_obstacle_count() -> int:
	return _ex.size()


## 走廊里因 MAX_NODE_OBSTACLES 上限而没生成节点的障碍数（> 0 = 碎带，路径可能变差或不可达）
func truncated_obstacle_count() -> int:
	return _truncated_count


func edge_count() -> int:
	return _edge_from.size()


func height() -> float:
	return _height


# ---------------------------------------------------------------- 准备阶段


func _reset() -> void:
	_height = 0.0
	_unit_radius = 0.0
	_start = Vector3.ZERO
	_goal = Vector3.ZERO
	_start_pushed = false
	_goal_pushed = false
	_ready = false
	_solved = false
	_direct = false
	_attempts = 0
	_solution = PackedVector3Array()
	_node_count = 0
	_cx = PackedFloat64Array()
	_cz = PackedFloat64Array()
	_cr = PackedFloat64Array()
	_obs_total = 0
	_sel = PackedInt32Array()
	_sel_count = 0
	_sel_max_radius = 0.0
	_truncated_count = 0
	_ex = PackedFloat64Array()
	_ez = PackedFloat64Array()
	_er = PackedFloat64Array()
	_edge_of_active = PackedInt32Array()
	_nx = PackedFloat64Array()
	_nz = PackedFloat64Array()
	_nobs = PackedInt32Array()
	_nslot = PackedInt32Array()
	_edge_from = PackedInt32Array()
	_edge_to = PackedInt32Array()
	_edge_weight = PackedFloat64Array()
	_adj_start = PackedInt32Array()
	_adj_to = PackedInt32Array()
	_adj_weight = PackedFloat64Array()


## 高度过滤 + 膨胀，结果摊平成三个 PackedFloat64Array
func _collect(obstacles: Array) -> void:
	var cx := _cx
	var cz := _cz
	var cr := _cr
	for index in obstacles.size():
		var raw: Variant = obstacles[index]
		if raw == null:
			push_error("[NavGraph] 障碍表第 %d 项是 null，跳过" % index)
			continue
		var obstacle := raw as NavObstacle
		if obstacle == null:
			push_error("[NavGraph] 障碍表第 %d 项不是 NavObstacle（实际 %s），跳过" % [
				index, type_string(typeof(raw))])
			continue
		if not obstacle.is_valid():
			push_error("[NavGraph] 障碍表第 %d 项数据不自洽（%s），跳过" % [
				index, obstacle.describe()])
			continue
		if not obstacle.blocks_at(_height):
			continue  # 单位在这个高度可以直飞，障碍整条剔除
		cx.append(obstacle.position.x)
		cz.append(obstacle.position.z)
		cr.append(obstacle.inflated_radius(_unit_radius, SAFETY_MARGIN))
	_cx = cx
	_cz = cz
	_cr = cr
	_obs_total = cx.size()


## 把点推到所有膨胀圈外（迭代，处理互相重叠的圈）。返回 Y = 该层巡航高度的点。
## 注意：点**在**圈上（相切）不算在圈内，见 NavObstacle.contains_xz。
func _clamp_point(point: Vector3) -> Vector3:
	var x := point.x
	var z := point.z
	var cx := _cx
	var cz := _cz
	var cr := _cr
	var count := _obs_total
	for iteration in CLAMP_ITERATIONS:
		var moved := false
		for i in count:
			var r := cr[i]
			if r <= 0.0:
				continue
			var dx := x - cx[i]
			var dz := z - cz[i]
			var r_eff := r - GEOMETRY_EPSILON
			var distance_squared := dx * dx + dz * dz
			if distance_squared >= r_eff * r_eff:
				continue
			var distance := sqrt(distance_squared)
			if distance < GEOMETRY_EPSILON:
				# 点正好压在圆心上：没有径向可言，用确定方向兜底（保证确定性）
				dx = 1.0
				dz = 0.0
				distance = 1.0
			x = cx[i] + dx / distance * r
			z = cz[i] + dz / distance * r
			moved = true
		if not moved:
			break
	return Vector3(x, _height, z)


# ---------------------------------------------------------------- 建图阶段


## 单次尝试：走廊分区 → 节点 → 边 → Dijkstra。返回 true 表示找到路径。
func _attempt(band: float) -> bool:
	if not _select(band):
		return false
	_build_nodes()
	if _node_count < 2:
		return false
	_build_edges()
	_build_adjacency()
	return _dijkstra()


## 走廊分区：选出“生成节点”与“参与边测试”的障碍。
##
## 节点集：到直段距离 ≤ band + r（挡路者必然入选，因为它们到直段距离 ≤ r），
##         再按距离升序只留最近的 MAX_NODE_OBSTACLES 个（碎带上限）
## 边集  ：到直段距离 ≤ band + r_max·(1 + 1/cos15°) + r
##         —— 带内节点的离轴距离上界就是 band + r·(1 + 1/cos15°)，带是凸的，
##            所以这个范围之外的圈不可能与任何带内线段相交
func _select(band: float) -> bool:
	_sel = PackedInt32Array()
	_sel_count = 0
	_sel_max_radius = 0.0
	_truncated_count = 0
	_ex = PackedFloat64Array()
	_ez = PackedFloat64Array()
	_er = PackedFloat64Array()
	_edge_of_active = PackedInt32Array()
	var total := _obs_total
	if total == 0:
		return false

	var cx := _cx
	var cz := _cz
	var cr := _cr
	var ax := _start.x
	var az := _start.z
	var bx := _goal.x
	var bz := _goal.z

	var distances := PackedFloat64Array()
	distances.resize(total)
	# 候选按“到直段的距离”升序插入；超上限就丢掉最远的（稳定插入 ⇒ 同距时先到先得，确定性）
	var kept := PackedInt32Array()
	var kept_distance := PackedFloat64Array()
	for i in total:
		var d := _point_segment_distance(cx[i], cz[i], ax, az, bx, bz)
		distances[i] = d
		if d > band + cr[i]:
			continue
		var slot := kept.size()
		while slot > 0 and kept_distance[slot - 1] > d:
			slot -= 1
		if slot >= MAX_NODE_OBSTACLES:
			_truncated_count += 1
			continue
		kept.insert(slot, i)
		kept_distance.insert(slot, d)
		if kept.size() > MAX_NODE_OBSTACLES:
			kept.resize(MAX_NODE_OBSTACLES)
			kept_distance.resize(MAX_NODE_OBSTACLES)
			_truncated_count += 1

	_sel = kept
	_sel_count = kept.size()
	if _sel_count == 0:
		return false
	for i in _sel_count:
		_sel_max_radius = maxf(_sel_max_radius, cr[kept[i]])

	var ex := PackedFloat64Array()
	var ez := PackedFloat64Array()
	var er := PackedFloat64Array()
	var owner := PackedInt32Array()
	owner.resize(total)
	owner.fill(-1)
	var edge_band := band + _sel_max_radius * (1.0 + RING_RADIUS_SCALE)
	for i in total:
		var r := cr[i]
		if distances[i] > edge_band + r:
			continue
		# 只有真要用的圈才拷一份数值；顺带记下反查表
		owner[i] = ex.size()
		ex.append(cx[i])
		ez.append(cz[i])
		er.append(r)
	_ex = ex
	_ez = ez
	_er = er
	_edge_of_active = owner
	return ex.size() > 0


## 节点 = 起点 + 终点 + 每个选中障碍的 12 个方位节点（已膨胀 + 外切多边形顶点）
## 落进别人膨胀圈里的方位节点直接丢掉（ADR-0004 的实现要点），否则会生成穿模的边。
func _build_nodes() -> void:
	var capacity := 2 + _sel_count * RING_SAMPLES
	var nx := PackedFloat64Array()
	var nz := PackedFloat64Array()
	var nobs := PackedInt32Array()
	var nslot := PackedInt32Array()
	nx.resize(capacity)
	nz.resize(capacity)
	nobs.resize(capacity)
	nslot.resize(capacity)

	var count := 0
	nx[count] = _start.x
	nz[count] = _start.z
	nobs[count] = -1
	nslot[count] = -1
	count += 1
	nx[count] = _goal.x
	nz[count] = _goal.z
	nobs[count] = -1
	nslot[count] = -1
	count += 1

	var cx := _cx
	var cz := _cz
	var cr := _cr
	var ex := _ex
	var ez := _ez
	var er := _er
	var edge_count := ex.size()
	var sel := _sel
	var owner_of := _edge_of_active

	for s in _sel_count:
		var active := sel[s]
		var owner := owner_of[active]
		if owner < 0:
			continue  # 数学上不会发生（节点集 ⊆ 边集）；真发生了宁可少撒一圈也不穿模
		var ring_radius := cr[active] * RING_RADIUS_SCALE
		var ox := cx[active]
		var oz := cz[active]
		for slot in RING_SAMPLES:
			var angle := TAU * float(slot) / float(RING_SAMPLES)
			var px := ox + cos(angle) * ring_radius
			var pz := oz + sin(angle) * ring_radius
			# 落在任何（边集里的）膨胀圈内 → 这个方位节点无意义，丢掉
			var inside := false
			for k in edge_count:
				var rr := er[k] - GEOMETRY_EPSILON
				var qx := px - ex[k]
				var qz := pz - ez[k]
				if qx * qx + qz * qz < rr * rr:
					inside = true
					break
			if inside:
				continue
			nx[count] = px
			nz[count] = pz
			nobs[count] = owner
			nslot[count] = slot
			count += 1

	nx.resize(count)
	nz.resize(count)
	nobs.resize(count)
	nslot.resize(count)
	_nx = nx
	_nz = nz
	_nobs = nobs
	_nslot = nslot
	_node_count = count


## 建边：所有可见的节点对。
##
## 同一个障碍圈上的两个节点：只有**相邻槽位**的弦是不穿模的（外切多边形的边），
## 其余弦都从这个圈内部穿过去，永远被挡 —— 直接跳过，省掉一批必然失败的测试。
##
## 内层循环刻意内联（不调 _segment_blocked）：O(N²·K) 的热点里，一次函数调用
## 加成员数组的反复属性查找，实测能吃掉一半以上的时间。
func _build_edges() -> void:
	_edge_from = PackedInt32Array()
	_edge_to = PackedInt32Array()
	_edge_weight = PackedFloat64Array()

	var nx := _nx
	var nz := _nz
	var nobs := _nobs
	var nslot := _nslot
	var ex := _ex
	var ez := _ez
	var er := _er
	var edge_count := ex.size()
	var n := _node_count
	var from_list := PackedInt32Array()
	var to_list := PackedInt32Array()
	var weight_list := PackedFloat64Array()

	for i in n:
		var ax := nx[i]
		var az := nz[i]
		var owner_i := nobs[i]
		for j in range(i + 1, n):
			var owner_j := nobs[j]
			var skip := -1
			if owner_i >= 0 and owner_i == owner_j:
				var slot_delta := absi(nslot[i] - nslot[j])
				if slot_delta != 1 and slot_delta != RING_SAMPLES - 1:
					continue
				skip = owner_i  # 相切边：自己的圈不参与判定（浮点误差会把它判成穿透）
			var bx := nx[j]
			var bz := nz[j]
			var dx := bx - ax
			var dz := bz - az
			var length_squared := dx * dx + dz * dz
			if length_squared <= 0.0:
				continue
			var min_x := minf(ax, bx)
			var max_x := maxf(ax, bx)
			var min_z := minf(az, bz)
			var max_z := maxf(az, bz)
			var blocked := false
			for k in edge_count:
				if k == skip:
					continue
				var r := er[k]
				var ox := ex[k]
				if ox + r < min_x or ox - r > max_x:
					continue
				var oz := ez[k]
				if oz + r < min_z or oz - r > max_z:
					continue
				var t := ((ox - ax) * dx + (oz - az) * dz) / length_squared
				if t < 0.0:
					t = 0.0
				elif t > 1.0:
					t = 1.0
				var qx := ax + dx * t - ox
				var qz := az + dz * t - oz
				if qx * qx + qz * qz < r * r:
					blocked = true
					break
			if blocked:
				continue
			var weight := sqrt(length_squared)
			from_list.append(i)
			to_list.append(j)
			weight_list.append(weight)
			from_list.append(j)
			to_list.append(i)
			weight_list.append(weight)

	_edge_from = from_list
	_edge_to = to_list
	_edge_weight = weight_list


## 直线快路径用：对**全部**活跃障碍做一次线段-圆相交测试（不跳过任何圈）
func _segment_blocked_all(ax: float, az: float, bx: float, bz: float) -> bool:
	var dx := bx - ax
	var dz := bz - az
	var length_squared := dx * dx + dz * dz
	if length_squared <= 0.0:
		return false
	var min_x := minf(ax, bx)
	var max_x := maxf(ax, bx)
	var min_z := minf(az, bz)
	var max_z := maxf(az, bz)
	var cx := _cx
	var cz := _cz
	var cr := _cr
	for i in _obs_total:
		var r := cr[i]
		var ox := cx[i]
		if ox + r < min_x or ox - r > max_x:
			continue
		var oz := cz[i]
		if oz + r < min_z or oz - r > max_z:
			continue
		var t := ((ox - ax) * dx + (oz - az) * dz) / length_squared
		if t < 0.0:
			t = 0.0
		elif t > 1.0:
			t = 1.0
		var qx := ax + dx * t - ox
		var qz := az + dz * t - oz
		if qx * qx + qz * qz < r * r:
			return true
	return false


## 平铺的边 → CSR 邻接表（计数排序，一次遍历）
func _build_adjacency() -> void:
	var n := _node_count
	var start := PackedInt32Array()
	start.resize(n + 1)
	start.fill(0)
	var edge_from := _edge_from
	var edge_to := _edge_to
	var edge_weight := _edge_weight
	var total := edge_from.size()
	for e in total:
		start[edge_from[e] + 1] += 1
	for i in n:
		start[i + 1] += start[i]
	var adj_to := PackedInt32Array()
	var adj_weight := PackedFloat64Array()
	adj_to.resize(total)
	adj_weight.resize(total)
	var cursor := PackedInt32Array()
	cursor.resize(n)
	for i in n:
		cursor[i] = start[i]
	for e in total:
		var from := edge_from[e]
		var slot := cursor[from]
		adj_to[slot] = edge_to[e]
		adj_weight[slot] = edge_weight[e]
		cursor[from] = slot + 1
	_adj_start = start
	_adj_to = adj_to
	_adj_weight = adj_weight


# ---------------------------------------------------------------- Dijkstra


## 从节点 0（起点）到节点 1（终点）的最短路。二叉堆 + 惰性删除。
##
## 复杂度 O(E log N)。堆里存节点下标，键从 dist 局部数组里读，所以不需要
## （距离, 节点）配对结构；重复入堆的旧条目靠 settled 标记跳过。
## 相等距离时**只有严格更优才更新**，因此同样的输入两次结果完全一致（验证用例 8）。
##
## push / pop 内联在循环里：E 条边各要一次 push，函数调用开销在 GDScript 里
## 是实打实的成本（每次约 0.2 µs）。
func _dijkstra() -> bool:
	var n := _node_count
	var dist := PackedFloat64Array()
	dist.resize(n)
	dist.fill(INFINITE)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var settled := PackedByteArray()
	settled.resize(n)
	settled.fill(0)

	var heap := PackedInt32Array()
	heap.resize(maxi(n * 4, 8))
	var heap_size := 0

	var adj_start := _adj_start
	var adj_to := _adj_to
	var adj_weight := _adj_weight
	var nx := _nx
	var nz := _nz

	dist[0] = 0.0
	heap[0] = 0
	heap_size = 1

	while heap_size > 0:
		# ---- pop 最小值（内联二叉堆下沉）----
		var u := heap[0]
		heap_size -= 1
		if heap_size > 0:
			var last := heap[heap_size]
			var last_key := dist[last]
			var hole := 0
			while true:
				var child := hole * 2 + 1
				if child >= heap_size:
					break
				var right := child + 1
				if right < heap_size and dist[heap[right]] < dist[heap[child]]:
					child = right
				var child_node := heap[child]
				if dist[child_node] >= last_key:
					break
				heap[hole] = child_node
				hole = child
			heap[hole] = last

		if settled[u] != 0:
			continue  # 惰性删除：同一节点可能有多条堆条目
		settled[u] = 1
		if u == 1:
			break
		var du := dist[u]
		var stop := adj_start[u + 1]
		for e in range(adj_start[u], stop):
			var v := adj_to[e]
			if settled[v] != 0:
				continue
			var candidate := du + adj_weight[e]
			if candidate < dist[v]:
				dist[v] = candidate
				prev[v] = u
				# ---- push（内联二叉堆上浮）----
				if heap_size >= heap.size():
					heap.resize(heap.size() * 2)
				var i := heap_size
				heap_size += 1
				while i > 0:
					var parent := (i - 1) >> 1
					var parent_node := heap[parent]
					if dist[parent_node] <= candidate:
						break
					heap[i] = parent_node
					i = parent
				heap[i] = v

	if dist[1] >= INFINITE:
		return false  # 不可达：起点被彻底围死（验证用例 6）

	var chain := PackedInt32Array()
	var cursor := 1
	while cursor != -1:
		chain.append(cursor)
		if cursor == 0:
			break
		cursor = prev[cursor]
	if chain[chain.size() - 1] != 0:
		return false

	var path := PackedVector3Array()
	path.resize(chain.size())
	var path_size := chain.size()
	for k in path_size:
		var index := chain[path_size - 1 - k]
		path[k] = Vector3(nx[index], _height, nz[index])
	_solution = path
	return true


# ---------------------------------------------------------------- 工具


func _x_z_distance(a: Vector3, b: Vector3) -> float:
	var dx := a.x - b.x
	var dz := a.z - b.z
	return sqrt(dx * dx + dz * dz)


## 两个点在 XZ 上是否同一个点（Y 不参与：Y 一律被改写成该层巡航高度）
func _same_xz(a: Vector3, b: Vector3) -> bool:
	return absf(a.x - b.x) <= GEOMETRY_EPSILON and absf(a.z - b.z) <= GEOMETRY_EPSILON


## 点到线段的 XZ 距离（走廊分区用）
func _point_segment_distance(px: float, pz: float,
		ax: float, az: float, bx: float, bz: float) -> float:
	var dx := bx - ax
	var dz := bz - az
	var length_squared := dx * dx + dz * dz
	if length_squared <= 0.0:
		var ex := px - ax
		var ez := pz - az
		return sqrt(ex * ex + ez * ez)
	var t := ((px - ax) * dx + (pz - az) * dz) / length_squared
	if t < 0.0:
		t = 0.0
	elif t > 1.0:
		t = 1.0
	var qx := ax + dx * t - px
	var qz := az + dz * t - pz
	return sqrt(qx * qx + qz * qz)
