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
## 单位已结算死亡并**从 _units 移除之后**才发（T-2.4）。
## killer_id = 造成致死一击的发射者，未知为 -1。
## 只发一次：死亡靠请求表去重 + alive 判定兼底，重复请求不会重复发。
signal unit_died(unit: Unit, killer_id: int)
## 给单位装上了新航线（表现层据此画路径线；空路径不会发）
signal route_assigned(unit: Unit, path: PackedVector3Array)
## 一条命令在 tick 里被处理完（units = 实际生效的单位数）
signal command_applied(kind: StringName, units: int)

## 命令 kind（与 InputMap action 名一致，见 scripts/input/input_router.gd）
const CMD_MOVE := &"cmd_move"
const CMD_ATTACK_MOVE := &"cmd_attack_move"
const CMD_STOP := &"cmd_stop"
## 改高度层（T-3.1）。**会话级**命令：不针对某个单位，options.layer = 层索引 0/1/2
const CMD_SET_LAYER := &"cmd_set_layer"
## 改阵型（T-3.3）。会话级命令：options.formation = Formation.Kind
const CMD_SET_FORMATION := &"cmd_set_formation"

## 默认高度层（ADR-0003 L1 = 0 m）。本卡所有单位都在 L1；切层归 S2 的高度指令。
const LAYER_CRUISE := 0.0

## 高度层中心（ADR-0003）。索引 0/1/2 = L0/L1/L2
const LAYER_CENTERS: Array[float] = [-400.0, 0.0, 400.0]
const LAYER_COUNT := 3
const LAYER_DEFAULT := 1
## 改层命令的 options 键
const OPTION_LAYER := &"layer"
## 改阵型命令的 options 键
const OPTION_FORMATION := &"formation"

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
var _layer_index := LAYER_DEFAULT
## 切层次数 / 因切层而重算的航线数（诊断用）
var _layer_changes := 0
var _repats := 0
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
## 最近一个 tick 里实际生成的弹体数（T-2.3）
var _shots_spawned := 0

## 追击（T-2.5）：attack_move 模式下目标超出开火距离就重新拉航线压上去。
## 节流间隔（秒）—— 寻路是整帧同步求解，不能每 tick 都拉一条线
const PURSUIT_INTERVAL := 0.5
## 已经能打到就不用追：留 10% 余量，避开在射程边缘反复起步/刹车
const PURSUIT_SLACK := 0.9
## 航线终点偏离目标超过这个距离（米）就重算。
##
## 不能拿 has_active_waypoint() 当闸门（T-3.2 踩出来的）：
## 两艘同队船共享同一航线终点时，分离系统把它们推开 67 m，而到站半径只有 2 m —
## 几何上不可能同时满足，于是它们绕着终点转圈，has_active_waypoint() 永远为真，
## 追击一次都不会触发（实测 pursuits=0，双方对望 230 秒）。
## 改成看“航线还指不指着目标”：终点漂移超过这个值才重拉。
const PURSUIT_RETARGET_DISTANCE := 200.0
## unit_id -> 剩余冷却秒数
var _pursuit_cooldown: Dictionary = {}
var _pursuits := 0
## 同队分离累计推开的对数（T-3.2，诊断用）
var _separations := 0

## 当前阵型（T-3.3）。群组移动命令按它分配槽位
var _formation := Formation.Kind.WEDGE
var _formation_changes := 0
## 按阵型分配的槽位数（诊断用）
var _formation_slots := 0
## 累计命中结算次数（T-2.3）
var _hits_applied := 0

## 请求表（T-2.4，ADR-0012 机制 #4）：本 tick 里产生的生成/销毁都先入队，
## 统一在第 8 步结算，保证第 1~7 步看到的集合恒定。
var _spawn_requests: Array[Dictionary] = []
## unit_id -> killer_id。用 Dictionary 而不是数组：重复请求天然去重。
var _kill_requests: Dictionary = {}

var _spawns_settled := 0
var _deaths_settled := 0

## 弹体管理与扫掠命中检测（ADR-0013）
var _projectiles := ProjectileManager.new()


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


## 请求生成（**不当场生效**）。到下一 tick 的第 8 步才真正生成。
## 用在 tick 中途需要“打完这行就多一艘”的场合（增援 / 分裂 / 孵化）；
## 初始化阶段直接调 spawn_unit 即可，不需要多绕一个 tick。
func request_spawn(def_id: String, position: Vector3, team: int = 0) -> void:
	_spawn_requests.append({"def_id": def_id, "position": position, "team": team})


## 请求销毁。只入队，不碰 _units；同 id 重复请求会被合并（保留最先的 killer）。
## 真正的伤害已经在目标侧结算完（apply_damage），这里只负责“从世界的名单里拿掉”。
func request_kill(unit_id: int, killer_id: int = -1) -> void:
	if not _kill_requests.has(unit_id):
		_kill_requests[unit_id] = killer_id


func spawn_request_count() -> int:
	return _spawn_requests.size()


func kill_request_count() -> int:
	return _kill_requests.size()


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
	# 容错：直接把层中心交给它（battle.gd 装配地图时就是这么用的）
	var index := LAYER_DEFAULT
	var best := INF
	for i in LAYER_CENTERS.size():
		var d := absf(LAYER_CENTERS[i] - height)
		if d < best:
			best = d
			index = i
	set_layer_index(index)


## 层索引（0/1/2）→ 层中心（米）
static func layer_center(index: int) -> float:
	return LAYER_CENTERS[clampi(index, 0, LAYER_COUNT - 1)]


func layer_index() -> int:
	return _layer_index


## 切到指定高度层。
##
## 切层**不是「只改一个数」**：它同时影响三件事
##   1. 该层哪些障碍参与寻路（NavObstacle.blocks_at）
##   2. 单位的巡航目标高度（UnitFlight.cruise_target_y）—— 自动生效，不需重算
##   3. **已有航线是否还合法** —— 必须重算。
##      否则会出现「在 L1 绕过 top=200 的岩石，升到 L2 后仍绕、
##      或者从 L2 降回 L1 后直接穿过岩石」两种错误。
func set_layer_index(index: int, repath: bool = true) -> void:
	var clamped := clampi(index, 0, LAYER_COUNT - 1)
	var next_height := LAYER_CENTERS[clamped]
	if clamped == _layer_index and is_equal_approx(_layer_height, next_height):
		return
	_layer_index = clamped
	_layer_height = next_height
	_layer_changes += 1
	if repath:
		_repath_active_routes()


## 切层后把还在飞的航线按新层重算一遍。
## 目的地取航线的**最后一个点**（原始终点），不是下一个 waypoint ——
## 按下一点重算会把单位的中途拐点当成新目的地，航程越切越短。
func _repath_active_routes() -> void:
	for unit in _units:
		if not unit.alive or not unit.has_active_waypoint():
			continue
		if unit.route.is_empty():
			continue
		var destination := unit.route[unit.route.size() - 1]
		_assign_route(unit, destination)
		_repats += 1


func layer_height() -> float:
	return _layer_height


# ---------------------------------------------------------------- 阵型（T-3.3）


func formation() -> int:
	return _formation


func formation_name() -> String:
	return Formation.kind_name(_formation)


## 切换阵型。只看“类型变没变”，相同则幂等返回。
##
## 平滑过渡的做法不是插值，而是**重新分配槽位 + 重算航线** ——
## 单位自己飞过去，天然就是平滑的，也不需要额外的动画状态机。
func set_formation(kind: int) -> void:
	var clamped := clampi(kind, 0, Formation.KIND_COUNT - 1)
	if clamped == _formation:
		return
	_formation = clamped
	_formation_changes += 1
	_reapply_formation()


## 把已经在下达阵型命令的编队按**新阵型**重新排一遍。
## 目的地取各成员航线终点的重心：用重心而不是某个人的终点，
## 因为不同成员原本的终点就已经分散在旧阵型槽位上，取重心才回到原来的落点。
func _reapply_formation() -> void:
	for squad in _squads:
		var members: Array[Unit] = []
		for unit in squad.alive_units():
			if unit.has_active_waypoint() and not unit.route.is_empty():
				members.append(unit)
		if members.size() < 2:
			continue
		var dest := Vector3.ZERO
		for unit in members:
			dest += unit.route[unit.route.size() - 1]
		dest /= float(members.size())
		_assign_formation_routes(members, dest, members[0].attack_move)


## 多单位移动：给每个单位分一个槽位，而不是让所有人飞向同一个点。
##
## 为什么要排序：命令里的单位顺序不一定稳定（框选顺序 / 数组拼接），
## 不排序的话同一个命令两次执行会得到不同槽位分配，回放就废了。
func _assign_formation_routes(units: Array[Unit], point: Vector3, is_attack: bool) -> void:
	var ordered: Array[Unit] = []
	for unit in units:
		if unit != null:
			ordered.append(unit)
	ordered.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)

	var spacing := Formation.spacing_for(ordered)
	var offsets := Formation.slot_offsets(ordered.size(), _formation, spacing)
	if offsets.is_empty():
		return

	# 队形朝向 = 从当前位置重心指向落点；两者重合时退化用 +Z（无方向）
	var from := _centroid(ordered)
	var forward := point - from

	for i in ordered.size():
		var unit: Unit = ordered[i]
		unit.attack_move = is_attack
		var destination := point + Formation.to_world(offsets[i], forward)
		_assign_route(unit, destination)
		_formation_slots += 1


func _centroid(units: Array[Unit]) -> Vector3:
	if units.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for unit in units:
		sum += unit.position
	return sum / float(units.size())


# ---------------------------------------------------------------- 命令


## 处理一条命令。cmd 结构 = CommandBus 的批次元素：
##   {"target": Unit | Array[Unit], "kind": StringName, "options": Dictionary}
## 只认 cmd_move / cmd_attack_move（S1 无武器，按移动处理）/ cmd_stop。
func handle_command(cmd: Dictionary) -> void:
	var kind: StringName = cmd.get("kind", &"")
	var options: Dictionary = cmd.get("options", {})

	# 改高度层是**会话级**命令，不针对任何单位。必须在解析 target 之前处理 ——
	# 否则「没有单位参数」会被下面的 targets.is_empty() 当成无效命令丢掉。
	if kind == CMD_SET_LAYER:
		var layer: int = int(options.get(OPTION_LAYER, _layer_index))
		set_layer_index(layer)
		_commands_applied += 1
		command_applied.emit(kind, 1)
		return

	# 改阵型同理：会话级，不看 units
	if kind == CMD_SET_FORMATION:
		var f: int = int(options.get(OPTION_FORMATION, _formation))
		set_formation(f)
		_commands_applied += 1
		command_applied.emit(kind, 1)
		return

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
			# 多单位 → 按阵型分槽位；单单位 → 直接去落点（不需要为 1 艘船排阵）
			if targets.size() > 1:
				_assign_formation_routes(targets, point, is_attack)
			else:
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
	_step_weapons(dt)        # 3b+ 炮塔瞄准 + 冷却 + 生弹体
	_step_projectiles(dt)    # 5/6 弹体推进 + 扫掠命中 + 伤害结算（ADR-0013）
	_step_pursuit(dt)        # 3c+ 追击：打不到就压上去（否则滞回带里永久卡死）
	_step_unit_movement(dt)  # 3c（含每单位 reset_accumulators）
	_step_separation(dt)     # 3d 同队分离（只写 accum，不碰 position）
	_apply_accumulators()    # 4
	_resolve_requests()      # 8

	_tick_index += 1


## 已完成的 tick 数
func tick_index() -> int:
	return _tick_index


## 弹体管理器（只读用途：表现层渲染弹体、验证场景造弹）。
## 注意：不要拿它绕过 tick 去改单位状态，命中结果只给记录。
func projectiles() -> ProjectileManager:
	return _projectiles


## ---------------------------------------------------------------- 胜负判定（T-2.5）

## 尚未分出胜负（还有 ≥ 2 队活着，或会战刚开始）
const NO_WINNER := -1
## 同归于尽：至少结算过死亡，且现在场上一个活人都没有
const MUTUAL_DESTRUCTION := -2


## 某队的存活单位数
func alive_count(team: int) -> int:
	var n := 0
	for unit in _units:
		if unit.alive and unit.team == team:
			n += 1
	return n


## 场上出现过的所有队伍号（升序）。死光了的队也算 —— 胜负判定需要知道“曾经有谁”。
func teams() -> Array[int]:
	var seen := {}
	for unit in _units:
		seen[unit.team] = true
	var out: Array[int] = []
	for key in seen.keys():
		out.append(int(key))
	out.sort()
	return out


## 胜负判定：只剩一队有活人 → 返回该队号。
##
## 三种“没赢家”要分清，不能都当成 0 队胜：
##   NO_WINNER (-1)          还在打，或还没开打
##   MUTUAL_DESTRUCTION (-2) 真打过了（有死亡结算），但现在一个活人都没有
func winner() -> int:
	var live: Array[int] = []
	for team in teams():
		if alive_count(team) > 0:
			live.append(team)
	if live.size() == 1:
		return live[0]
	if live.is_empty() and _deaths_settled > 0:
		return MUTUAL_DESTRUCTION
	return NO_WINNER


func is_battle_over() -> bool:
	return winner() != NO_WINNER


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
		var wanted: int = unit.weapons.tick(unit, target.position, dt)
		_shots_wanted += wanted
		_shots_spawned += _spawn_shots(unit, target, wanted)


## 把「想开火」变成真弹体。弹体本身不做任何命中判断，只负责运动学。
func _spawn_shots(unit: Unit, target: Unit, count: int) -> int:
	if count <= 0:
		return 0
	var mounts := unit.weapons.mounts()
	if mounts.is_empty():
		return 0
	var spawned := 0
	for i in count:
		var mount: WeaponMount = mounts[i % mounts.size()]
		var def: WeaponDef = mount.def
		if def == null:
			continue
		var origin := unit.position + unit.forward * unit.radius * 0.9 + mount.local_offset
		var dir := target.position - origin
		_projectiles.spawn(origin, dir, def.projectile_speed, def.damage,
			unit.team, unit.id, 0.8, 4.0)
		spawned += 1
	return spawned


## 第 5/6 步：弹体推进 + 扫掠命中（ADR-0013）。
##
## 命中只产记录，**伤害在目标侧结算**：ProjectileManager 不碰单位状态，
## apply_damage() 是唯一伤害入口。这样弹体可以单独测、将来做回放不用重算物理。
func _step_projectiles(dt: float) -> void:
	if _projectiles.active_count() == 0:
		return
	var hits := _projectiles.tick(_units, dt)
	for hit in hits:
		var target := _context.unit_by_id(hit["target_id"])
		if target == null:
			continue
		# apply_damage 是唯一伤害入口，返回本次是否致死
		var lethal := target.apply_damage(hit["damage"])
		if lethal:
			# 只入队，不在这里改 _units（硬规则 6）
			request_kill(target.id, int(hit.get("owner_id", -1)))
	_hits_applied += hits.size()


## 3c+ 追击：attack_move 模式下，目标超出开火距离就重新拉航线压上去。
##
## **为什么这一步不能省**（T-2.5 实测挖出来的）：
##   状态机进入 ATTACKING 的门槛是 weapon_range，退出是 1.25×weapon_range。
##   落在 (range, 1.25×range] 这个滞回带里就彻底卡死：
##   打不到（超出射程）、也不退（还在滞回带内）、而且没有任何一条边会去追。
##   实测 5v5 双方各剩 2 艘时相距 2120 m（射程 1800）对望 230 秒，命中数一动不动。
##
## 只对 attack_move 生效：普通「移动到 A」的语义是“别管闲事过去”，
## 自动追敌会让玩家觉得命令不听话（与 _step_moving 的判断口径一致）。
func _step_pursuit(dt: float) -> void:
	for unit in _units:
		if not unit.alive or not unit.attack_move:
			continue
		var cooldown := float(_pursuit_cooldown.get(unit.id, 0.0)) - dt
		if cooldown > 0.0:
			_pursuit_cooldown[unit.id] = cooldown
			continue
		var target := _context.unit_by_id(unit.target_id)
		if target == null:
			continue
		# 开火距离 = min(交战距离, 最远炮塔射程)：两个数据源不一致时不赌，取严的
		var fire_range := unit.weapon_range
		if unit.weapons != null:
			var mount_range := unit.weapons.max_range()
			if mount_range > 0.0:
				fire_range = minf(fire_range, mount_range)
		if unit.position.distance_to(target.position) <= fire_range * PURSUIT_SLACK:
			continue
		# 航线还基本指向目标 → 不重复拉（避免每 0.5 s 把航线重置一次导致原地画圈）
		if unit.has_active_waypoint() and not unit.route.is_empty():
			var destination := unit.route[unit.route.size() - 1]
			if destination.distance_to(target.position) <= PURSUIT_RETARGET_DISTANCE:
				continue
		_pursuit_cooldown[unit.id] = PURSUIT_INTERVAL
		_pursuits += 1
		_assign_route(unit, target.position)


## 把本 tick 的只读视图刷进 BattleContext（AI 只看它，不看本类）
func _sync_context() -> void:
	_context.sync(_units, _squads, _tick_index)


## 3d 同队单位分离（T-3.2）：多艘船追同一个目标会收敛到同一点，视觉上叠成一团。
## 必须在 _step_unit_movement 之后（那时 accum_position 已包含本 tick 位移）、
## 在 _apply_accumulators 之前（分离量和其他位移一起从唯一入口落到 position）。
func _step_separation(dt: float) -> void:
	_separations += UnitSeparation.apply(_units, dt)


func _apply_accumulators() -> void:
	for unit in _units:
		if not unit.alive:
			continue
		unit.apply_accumulators()


## 第 8 步：请求-结算两段式（T-2.4，ADR-0012 机制 #4）。
##
## 硬规则 6：遍历中不改集合。所以本 tick 产生的「要生成 / 要销毁」都只进请求表，
## 统一在这里结算。好处：
##   · 第 1~7 步看到的集合恒定，索敌 / 移动 / 弹体不会踩到半改的数组
##   · 死亡信号的发射点全工程只有一个
##   · unit_died 天然只发一次
func _resolve_requests() -> void:
	_settle_spawns()
	_settle_kills()


## 结算生成请求：按入队顺序，保证确定性。
func _settle_spawns() -> void:
	if _spawn_requests.is_empty():
		return
	var batch := _spawn_requests
	_spawn_requests = []
	for req in batch:
		var unit := spawn_unit(req["def_id"], req["position"], int(req["team"]))
		if unit != null:
			_spawns_settled += 1


## 结算销毁请求。
##
## 三段式，顺序不能换：
##   1. 并上兼底条目：alive 已经为 false 、却没进请求表的（剧本杀 / 外部直接置死）也要清
##   2. 一次移除 + 清死掉的索敌目标 + 重建编队
##   3. **最后**才发 unit_died —— 监听者拿到的 session 状态已经自洽，
##      不会出现「收到死亡通知但 unit_count() 还没减」这种中间态
func _settle_kills() -> void:
	if _kill_requests.is_empty() and not _has_dead_unit():
		return

	var pending := _kill_requests
	_kill_requests = {}

	# 兼底：没进请求表但已经死了的，补一条（killer 未知记 -1）
	for unit in _units:
		if not unit.alive and not pending.has(unit.id):
			pending[unit.id] = -1

	if pending.is_empty():
		return

	var dead: Array[Unit] = []
	var survivors: Array[Unit] = []
	for unit in _units:
		if pending.has(unit.id) and not unit.alive:
			dead.append(unit)
		else:
			survivors.append(unit)

	if dead.is_empty():
		return

	_units = survivors

	# 索敌目标已不在存活名单里 → 清掉，否则下一 tick 会一直拿着一个不存在的 id
	var live := {}
	for unit in _units:
		live[unit.id] = true
	for squad in _squads:
		if squad.has_target() and not live.has(squad.target_id):
			squad.clear_target()

	_rebuild_squads()

	# 确定性：同一 tick 内多个死亡按 id 升序通知
	dead.sort_custom(func(a: Unit, b: Unit) -> bool: return a.id < b.id)
	for unit in dead:
		_deaths_settled += 1
		unit_died.emit(unit, int(pending.get(unit.id, -1)))


func _has_dead_unit() -> bool:
	for unit in _units:
		if not unit.alive:
			return true
	return false


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
		"layer_index": _layer_index,
		"layer_changes": _layer_changes,
		"layer_repaths": _repats,
		"formation": _formation,
		"formation_changes": _formation_changes,
		"formation_slots": _formation_slots,
		"ticks": _tick_index,
		"squads": _squads.size(),
		"squads_with_target": squads_with_target,
		"weapon_mounts": weapon_mount_count(),
		"shots_wanted": _shots_wanted,
		"shots_spawned": _shots_spawned,
		"hits_applied": _hits_applied,
		"pursuits": _pursuits,
		"separations": _separations,
		"spawns_settled": _spawns_settled,
		"deaths_settled": _deaths_settled,
		"pending_spawns": _spawn_requests.size(),
		"pending_kills": _kill_requests.size(),
		"projectiles": _projectiles.stats(),
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
