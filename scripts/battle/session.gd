class_name BattleSession
extends RefCounted

## 战斗会话（L1 模拟层的中枢，见 docs/ARCHITECTURE.md「四层与依赖方向」）。
##
## 一句话职责：把「命令 → 航线 → 每 tick 积分」这条链串起来，且自己**不是**节点。
##
## 为什么是 RefCounted 而不是 Node（本卡的硬约束之一）：
##   模拟层必须能脱离场景树单测（硬规则 2 / 五核心接口之 Simulation）。
##   本类不读 transform、不摸 viewport、不在 _process 里推进自己 ——
##   tick(dt) 由外部（Simulation.ticked / 验证场景）显式调用。
##   唯一的 Node 依赖是构造时**注入**的 CommandBus 对象；传 null 也能只跑移动。
##
## 职责边界：
##   ✅ 从 Registry 生成 Unit（机型数据走 UnitDef，代码里没有资源路径）
##   ✅ 持有障碍表（NavObstacle）并同步给 NavigationService
##   ✅ 订阅 CommandBus.command_issued → 在 tick 开头 flush（九步的第 1 步）
##   ✅ 按固定顺序驱动移动：reset_accumulators → UnitMovement.step → apply_accumulators
##   ✅ 按 team 自动分编队（Squad），每 tick 把只读视图刷进 BattleContext
##   ✅ 九步里的第 3 步按文档顺序拆成三段：状态机决策 → 索敌（节流）→ 移动累积
##   ✅ 诊断计数（命令 / 路径 / 不可达）
##   ❌ 不做仲裁（CommandBus 内部，硬规则 1）
##   ❌ 不做选靶算法（Targeting）/ 状态迁移（UnitStates）—— 本类只按顺序调用它们
##   ❌ 不写 Unit 的 position / route（那是 UnitMovement 与命令处理的职责）
##   ❌ 不碰任何场景节点 / 渲染（硬规则 4）
##
## AI 接线为什么集中在这里而不是散到各处：
##   九步顺序是硬规则（ARCHITECTURE「模拟循环顺序」）。"谁先谁后"只允许有一处实现，
##   否则某天有人在 UnitMovement 里顺手补一句"发现敌人就切状态"，顺序就废了。
##
## 命令为什么先入队再在 tick 里处理：
##   command_issued 是"已接受"的信号，不是"立刻执行"的授权。
##   统一在 tick 的第 1 步处理，才能保证"一帧内多条命令"的顺序与「模拟循环顺序」
##   一致，也才能让寻路的时间预算（NavigationService.reset_frame）有意义。
##   TODO(S3)：接上 route_or_defer 的分帧摊销，把重算摊到多个 tick。

## 生成了一个单位（表现层据此挂 UnitView）
signal unit_spawned(unit: Unit)
## 给单位装上了新航线（表现层据此画路径线；空路径不会发）
signal route_assigned(unit: Unit, path: PackedVector3Array)
## 一条命令在 tick 里被处理完（units = 实际生效的单位数）
signal command_applied(kind: StringName, units: int)

## 命令 kind（与 InputMap action 名一致，见 scripts/input/input_router.gd）
const CMD_MOVE := &"cmd_move"
const CMD_ATTACK_MOVE := &"cmd_attack_move"
const CMD_STOP := &"cmd_stop"

## 默认高度层（ADR-0003 L1 = 0 m）。本卡所有单位都在 L1；切层归 S2 的高度指令。
const LAYER_CRUISE := 0.0

## 命令里世界落点的键名（InputRouter._point_options 的约定）
const OPTION_POINT := "point"
## 命令来源键（仲裁用，S1 只记录）
const OPTION_SOURCE := "source"


## L0 注册表（生成单位用；由 setup 注入，不在本类里调 GameState）
var _registry: Registry = null
## CommandBus（本类唯一的外部对象依赖；可以为 null = 只跑移动）
var _bus: Object = null

## 寻路服务（持有障碍表 + 计量）。本类不自己实现几何。
var _nav := NavigationService.new()
## 障碍表（NavObstacle）。增删后脏标记，下一次 route 前同步给 _nav。
var _obstacles: Array[NavObstacle] = []
var _obstacles_dirty := false

## 本会话的单位（顺序 = 生成顺序；遍历顺序稳定 = 可回放）
var _units: Array[Unit] = []
## 本会话的编队（一队一个，按 team 自动生成；顺序 = 首次出现该队伍的生成顺序）
var _squads: Array[Squad] = []
## 下一个编队 ID（1 起，单调递增）
var _next_squad_id := 1
## 集中选靶（编队级共享目标，1 秒节流 —— ADR-0012 机制 #1）
var _targeting := Targeting.new()
## AI 只读上下文（每 tick 刷一次，避免 AI 直接摸本类）
var _context := BattleContext.new()
## 下一个分配的运行时 ID（1 起，单调递增）
var _next_id := 1

## 待处理命令（信号入队，tick 第 1 步消费）
var _pending_commands: Array = []

## 当前高度层中心（米，ADR-0003）
var _layer_height := LAYER_CRUISE
## 已完成的 tick 数
var _tick_index := 0

# ---------------------------------------------------------------- 诊断计数

var _commands_received := 0
var _commands_applied := 0
var _route_requests := 0
var _routes_assigned := 0
var _unreachable := 0
var _ignored_commands := 0
var _foreign_targets := 0
var _last_path_points := 0
## 机型数据缺键的兜底报告：def_id -> PackedStringArray（缺哪些键）
var _data_warnings: Dictionary = {}
## 最近一个 tick 里“想开火”的炮塔数（T-2.2）
var _shots_wanted := 0


# ---------------------------------------------------------------- 装配


## 注入依赖。bus 可为 null（无头移动测试 / 只跑积分的场景）。
## registry 必须是已加载的 Registry（加载失败时 spawn_unit 会报错，不会静默生成空船）。
func setup(registry: Registry, bus: Object = null) -> void:
	_registry = registry
	_bus = bus
	_context.bind_registry(registry)
	if bus != null and bus.has_signal(&"command_issued"):
		var handler := Callable(self, &"_on_command_issued")
		if not bus.is_connected(&"command_issued", handler):
			bus.connect(&"command_issued", handler)


## 断开 CommandBus 订阅。验证场景在用例之间必须调用，否则旧 session 会继续收命令
## （CommandBus 是 autoload，生命周期比任何验证用例都长）。
func shutdown() -> void:
	if _bus != null and _bus.has_signal(&"command_issued"):
		var handler := Callable(self, &"_on_command_issued")
		if _bus.is_connected(&"command_issued", handler):
			_bus.disconnect(&"command_issued", handler)
	_bus = null
	_pending_commands.clear()


# ---------------------------------------------------------------- 单位生成


## 从注册表生成一艘单位。def_id = 目录名（如 ou134）；position = 世界坐标（米）。
## team = 队伍号（决定归属哪个 Squad，以及索敌时的敌我判定）。
## 返回 null 表示数据不可用（未知 ID / 缺关键统计），错误已由 Registry / 本类报出。
func spawn_unit(def_id: String, position: Vector3, team: int = 0) -> Unit:
	if _registry == null:
		push_error("[BattleSession] Registry 未注入，无法生成单位 '%s'" % def_id)
		return null
	var record := _registry.unit(def_id)
	if record.is_empty():
		return null  # Registry.unit 已 push_error

	var def := UnitDef.from_record(def_id, record)
	if not def.is_valid():
		# 缺键清单同时进 _data_warnings：拒绝生成也要能在诊断里立刻看到"缺哪几个键"
		var missing := def.missing_keys()
		if not missing.is_empty():
			_data_warnings[def_id] = missing
		push_error("[BattleSession] 单位 '%s' 数据不完整，拒绝生成：%s" % [def_id, def.describe()])
		return null

	var unit := Unit.new(_next_id, def_id)
	_next_id += 1
	def.apply_to(unit)
	unit.position = position
	unit.team = team
	# 生成瞬间：机头默认 -Z，速度 0（不继承任何前一个单位的残余状态）
	unit.forward = Unit.DEGENERATE_FORWARD
	unit.speed = 0.0
	unit.clear_route()
	unit.reset_accumulators()
	# 炮塔组来自 unit.tbl 的 [weapon]（main / count / spread），武器数据来自 content/weapons/
	unit.weapons = UnitWeapons.build(unit, def_id, _context)

	_units.append(unit)
	_attach_to_squad(unit)
	unit_spawned.emit(unit)
	return unit


## 本会话的编队（副本）。编队按 team 自动生成，本卡没有"手动编队"指令。
func squads() -> Array[Squad]:
	var out: Array[Squad] = []
	out.append_array(_squads)
	return out


func squad_count() -> int:
	return _squads.size()


## AI 只读上下文（验证场景 / 调试面板用；AI 自己拿到的就是这一个对象）
func context() -> BattleContext:
	return _context


## 本会话的单位列表（副本；调用方不得原地改）
func units() -> Array[Unit]:
	var out: Array[Unit] = []
	out.append_array(_units)
	return out


func unit_count() -> int:
	return _units.size()


# ---------------------------------------------------------------- 障碍


## 追加一个导航障碍（已在表里则不重复加）
func add_obstacle(obstacle: NavObstacle) -> void:
	if obstacle == null:
		push_error("[BattleSession] add_obstacle(null)：忽略")
		return
	if _obstacles.has(obstacle):
		return
	_obstacles.append(obstacle)
	_obstacles_dirty = true


## 障碍表（副本；NavObstacle 本身是引用，改字段会直接影响寻路 —— 约定只读）
func obstacles() -> Array[NavObstacle]:
	var out: Array[NavObstacle] = []
	out.append_array(_obstacles)
	return out


func obstacle_count() -> int:
	return _obstacles.size()


## 当前高度层中心（米）。改层时下一次寻路会按新层高度过滤障碍（ADR-0003）。
func set_layer_height(height: float) -> void:
	_layer_height = height


func layer_height() -> float:
	return _layer_height


# ---------------------------------------------------------------- 命令


## 处理一条命令。cmd 结构 = CommandBus 的批次元素：
##   {"target": Unit | Array[Unit], "kind": StringName, "options": Dictionary}
## 只认 cmd_move / cmd_attack_move（S1 无武器，按移动处理）/ cmd_stop。
func handle_command(cmd: Dictionary) -> void:
	var kind: StringName = cmd.get("kind", &"")
	var options: Dictionary = cmd.get("options", {})
	var targets := _resolve_targets(cmd.get("target", null))
	if targets.is_empty():
		_ignored_commands += 1
		return

	match kind:
		CMD_MOVE, CMD_ATTACK_MOVE:
			var point: Variant = options.get(OPTION_POINT, null)
			if typeof(point) != TYPE_VECTOR3:
				push_error("[BattleSession] %s 命令缺少世界落点 point（实际 %s），忽略" % [
					String(kind), type_string(typeof(point))])
				_ignored_commands += 1
				return
			# 攻防模式写进 Unit，由状态机决定"途中遇敌要不要拐一下"（UnitStates._step_moving）
			var is_attack := kind == CMD_ATTACK_MOVE
			for unit in targets:
				unit.attack_move = is_attack
				_assign_route(unit, point)
		CMD_STOP:
			for unit in targets:
				unit.attack_move = false
				unit.clear_route()
		_:
			# 攻击 / 改高度层等：S1 不实现，记数不报错（命令本身是合法的，只是还没有系统接）
			_ignored_commands += 1
			return

	_commands_applied += 1
	command_applied.emit(kind, targets.size())


## 给一个单位算航线并装上。空路径 = 不可达 → 停止（保留原地的 "不动" 语义，
## 绝不把空路径当成"瞬移到原点"）。
func _assign_route(unit: Unit, point: Vector3) -> void:
	_sync_obstacles()
	# 寻路高度用**该单位在本层的巡航目标高度**：height 决定哪些障碍参与计算，
	# 也决定返回路径的 Y。与 UnitFlight 的目标高度同源，避免"路径在 0，船却在 +150"。
	var height := UnitFlight.cruise_target_y(unit, _layer_height)
	var path := _nav.route(unit.position, point, unit.radius, height)
	_route_requests += 1
	_last_path_points = path.size()
	if path.is_empty():
		_unreachable += 1
		unit.clear_route()
		return
	_fix_start_point(path, unit.position)
	unit.set_route(path)
	_routes_assigned += 1
	route_assigned.emit(unit, path)


## 路径首点的语义是「你脚下」，但 NavGraph 统一把整条路径的 Y 写成层高。
## 对 cruise_altitude ≠ 0 的机型（ou05 偏 +80 m）首点会落在船正上方 80 m：
## 3D 到站判定（Unit.ARRIVAL_RADIUS = 2 m）永远差这 80 m，船会绕着首点打转
## （转弯半径 = v/ω ≈ 90 m 接近剩余距离，于是原地转圈），永远飞不到第二点。
## 所以把首点改写成本身的实际位置。**点数不变、后续点一个不改** ——
## 不影响寻路层的几何保证（膨胀 / 撑开），也不改导航服务的语义。
static func _fix_start_point(path: PackedVector3Array, position: Vector3) -> void:
	if path.is_empty():
		return
	var xz := Vector2(path[0].x - position.x, path[0].z - position.z)
	if xz.length() <= Unit.ARRIVAL_RADIUS:
		path[0] = position


## 命令目标 → 本会话的单位列表。
## 接受单个 Unit / Unit 数组（InputRouter 的选择列表就是后者）；
## 不是 Unit 的条目（Vector3 候选、表现节点等）直接跳过。
## 只处理**本会话**的单位：多个 session 同时在线时，别人的命令不该被自己执行。
func _resolve_targets(target: Variant) -> Array[Unit]:
	var out: Array[Unit] = []
	if target is Unit:
		_collect_owned(target, out)
	elif target is Array:
		for item in target:
			if item is Unit:
				_collect_owned(item, out)
	if out.is_empty():
		# 兜底：目标里没有可用的 Unit —— 用 GameState 的选中镜像（选择逻辑的落点）
		for item in GameState.selected_units():
			if item is Unit:
				_collect_owned(item, out)
	return out


func _collect_owned(unit: Unit, out: Array[Unit]) -> void:
	if not _units.has(unit):
		_foreign_targets += 1
		return
	if out.has(unit):
		return
	out.append(unit)


## CommandBus 信号 → 入队（tick 第 1 步统一处理，见文件头）
func _on_command_issued(unit_or_group: Variant, kind: StringName, options: Dictionary) -> void:
	_commands_received += 1
	_pending_commands.append({
		"target": unit_or_group,
		"kind": kind,
		"options": options.duplicate(true),
	})


# ---------------------------------------------------------------- 每 tick 驱动


## 走一个固定步长。顺序遵循 docs/ARCHITECTURE.md 的「模拟循环顺序」：
##   1 命令 flush
##   → 3 单位决策：3a 状态机 → 3b 索敌（节流）→ 3c 移动累积（reset → UnitMovement.step）
##   → 4 累加器统一应用
##   → 8 请求表结算（死亡清理 + 编队重建）
## 第 2 / 5 / 6 / 7 / 9 步在 S1 还没有内容（时钟 / 弹体 / 命中 / 技能 / 快照），
## 归由 Simulation 与后续卡处理；本类只负责第 1、3、4、8 步里与单位相关的部分。
##
## 为什么 3a 在 3b 之前：ARCHITECTURE 写的就是「状态机决策 → 索敌 → 移动累积」。
## 代价是状态机看到的是上一 tick 的共享目标（索敌本身 1 秒才扫一次，这一个 tick 的延迟
## 完全被节流吞掉了），换来的是"顺序只有文档一个来源"。
func tick(dt: float) -> void:
	if dt <= 0.0 or not is_finite(dt):
		push_error("[BattleSession] dt 非法（%f），跳过本次 tick" % dt)
		return

	# 寻路时间预算按 tick 记账（S1 同步求解；接口先接上，S3 换成分帧摊销）
	_nav.reset_frame()

	_step_commands()         # 1
	_sync_context()          # AI 只读视图（命令处理完才刷，新生成的单位本 tick 就能被看到）
	_step_unit_orders(dt)    # 3a 个体状态机
	_step_targeting(dt)      # 3b 编队级集中选靶（1 秒节流）
	_step_weapons(dt)        # 3b+ 炮塔瞄准与冷却（只报“想开火”数，不生弹体）
	_step_unit_movement(dt)  # 3c（含每单位 reset_accumulators）
	_apply_accumulators()    # 4
	_resolve_requests()      # 8

	_tick_index += 1


## 已完成的 tick 数
func tick_index() -> int:
	return _tick_index


func _step_commands() -> void:
	if _pending_commands.is_empty():
		return
	# 整批取走：处理过程中新入队的命令留到下一 tick，保证本 tick 的命令集合稳定
	var batch := _pending_commands
	_pending_commands = []
	for cmd in batch:
		handle_command(cmd)


func _step_unit_movement(dt: float) -> void:
	for unit in _units:
		if not unit.alive:
			continue
		# 硬规则 3：tick 开头清残留，UnitMovement 只写 accum_*，绝不直接改 position
		unit.reset_accumulators()
		UnitMovement.step(unit, dt, _layer_height)


## 3a 个体状态机（UnitStates）。只写 state / state_time / state_changes，不动位置。
func _step_unit_orders(dt: float) -> void:
	for unit in _units:
		if not unit.alive:
			continue
		UnitStates.step(unit, _context, dt)


## 3b 编队级集中选靶（Targeting）。节流在它内部，本类不做“隔几个 tick 才跳”的分支 ——
## 节流阈值只有一个来源（Targeting.SCAN_INTERVAL）。
func _step_targeting(dt: float) -> void:
	_targeting.update(_context, dt)


## 3b+ 炮塔瞄准与冷却（ADR-0012 机制 #11 的下半层）。
## 有目标的单位：weapons.tick() 推进瞄准 + 冷却，返回“想开火”的炮塔数；
## 没目标的单位：只推冷却（炮塔不转，但不能靠“没目标”白嫆冷却）。
## **不生弹体、不判命中、不算伤害** —— 那是 T-2.3。
func _step_weapons(dt: float) -> void:
	_shots_wanted = 0
	for unit in _units:
		if not unit.alive or unit.weapons == null:
			continue
		var target := _context.unit_by_id(unit.target_id)
		if target == null:
			unit.weapons.tick_cooldowns(dt)
			continue
		_shots_wanted += unit.weapons.tick(unit, target.position, dt)


## 把本 tick 的只读视图刷进 BattleContext（AI 只看它，不看本类）
func _sync_context() -> void:
	_context.sync(_units, _squads, _tick_index)


func _apply_accumulators() -> void:
	for unit in _units:
		if not unit.alive:
			continue
		unit.apply_accumulators()


## 第 8 步里与单位相关的部分：死亡清理 + 编队重建。遍历中不改集合（硬规则 6），先收集再重建。
func _resolve_requests() -> void:
	var has_dead := false
	for unit in _units:
		if not unit.alive:
			has_dead = true
			break
	if not has_dead:
		return
	var survivors: Array[Unit] = []
	for unit in _units:
		if unit.alive:
			survivors.append(unit)
	_units = survivors
	_rebuild_squads()


# ---------------------------------------------------------------- 诊断


## 会话统计。前四个键是本卡规格要求的（单位数 / 活跃路线数 / 已抵达数 / 不可达数），
## 其余是给验证场景与调试面板的补充。键名固定，不要各自另加计数器。
func stats() -> Dictionary:
	var active_routes := 0
	var arrived := 0
	var states := {}
	for unit in _units:
		if unit.has_active_waypoint():
			active_routes += 1
		if unit.is_route_finished() and not unit.route.is_empty():
			arrived += 1
		var name := UnitStates.state_name(unit.state)
		states[name] = int(states.get(name, 0)) + 1
	var squads_with_target := 0
	for squad in _squads:
		if squad.has_target():
			squads_with_target += 1
	return {
		"units": _units.size(),
		"active_routes": active_routes,
		"arrived": arrived,
		"unreachable": _unreachable,
		"commands_received": _commands_received,
		"commands_applied": _commands_applied,
		"route_requests": _route_requests,
		"routes_assigned": _routes_assigned,
		"ignored_commands": _ignored_commands,
		"foreign_targets": _foreign_targets,
		"last_path_points": _last_path_points,
		"obstacles": _obstacles.size(),
		"layer_height": _layer_height,
		"ticks": _tick_index,
		"squads": _squads.size(),
		"squads_with_target": squads_with_target,
		"weapon_mounts": weapon_mount_count(),
		"shots_wanted": _shots_wanted,
		"states": states,
	}


## 本会话全部单位的炮塔总数（诊断用）
func weapon_mount_count() -> int:
	var total := 0
	for unit in _units:
		if unit.weapons != null:
			total += unit.weapons.mount_count()
	return total


## 集中选靶的计量快照（扫描次数 / 候选数 / 目标切换次数）
func targeting_stats() -> Dictionary:
	return _targeting.stats()


## 寻路服务的计量快照（请求数 / 耗时 / 节点数 / 预算）
func navigation_stats() -> Dictionary:
	return _nav.stats()


## 机型数据缺键报告（def_id → 缺哪些统计键）。空字典 = 全部来自 TBL。
## T-2.0 起缺键 = 坏数据，对应单位根本不会被生成（见 UnitDef.from_record）。
func data_warnings() -> Dictionary:
	return _data_warnings.duplicate(true)


## 最近一个 tick 里“想开火”的炮塔数（T-2.2：只计数，不生弹体）
func shots_wanted() -> int:
	return _shots_wanted


# ---------------------------------------------------------------- 内部


## 把一个单位挂到它 team 对应的编队上。没有就新建一个（本卡一队一个编队）。
## 为什么不按“选中框”分编队：S1 没有编队指令，能自动分组的唯一依据就是队伍号。
func _attach_to_squad(unit: Unit) -> void:
	for squad in _squads:
		if squad.team == unit.team:
			squad.add_unit(unit)
			return
	var squad := Squad.new(_next_squad_id, unit.team)
	_next_squad_id += 1
	squad.add_unit(unit)
	_squads.append(squad)


## 死亡清理后重建编队成员表（只在本 tick 真有人死时才调，见 _resolve_requests）。
## 空编队直接丢弃：一个没有活人的 Squad 留在表里只会让寻敌循环多跑一圈空集。
## 不担心“队伍全员阵亡后编队消失”：同队新单位生成时 _attach_to_squad 会重建一个。
func _rebuild_squads() -> void:
	var surviving: Array[Squad] = []
	for squad in _squads:
		var members: Array[Unit] = []
		for unit in squad.units:
			if unit.alive and _units.has(unit):
				members.append(unit)
		squad.units = members
		if members.is_empty():
			continue
		surviving.append(squad)
	_squads = surviving


## 障碍表脏了才推给寻路服务（NavigationService 会浅拷一份，所以只在变更后同步）
func _sync_obstacles() -> void:
	if not _obstacles_dirty:
		return
	_nav.set_obstacles(_obstacles)
	_obstacles_dirty = false
