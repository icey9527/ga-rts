extends Node3D

## 战斗场景装配器。本文件是**接线**，不是逻辑：模拟在 BattleSession，命令在 CommandBus，
## 输入在 InputRouter，相机在 RtsCameraRig（见 docs/ARCHITECTURE.md 四层与依赖方向）。
##
## 节点树约定：
##   Battle (Node3D)        ← 本脚本，战斗场景根
##     World (Node3D)       ← 静态场景：环境 / 障碍 / 路径线
##     Units (Node3D)       ← 单位表现节点（UnitView，只读模拟数据，硬规则 4）
##     Camera (Node3D)      ← RtsCameraRig：2D/3D 双相机 + 唯一 ViewProjection（T-1.2）
##     InputRouter (Node)   ← 输入路由（T-1.3）：action → 相机 / 选择 / CommandBus
##
## 单向数据流（本文件是唯一接线处）：
##   CommandBus.command_issued → BattleSession（session 内部入队）
##   Simulation.ticked         → BattleSession.tick(dt)
##   BattleSession.unit_spawned → 挂 UnitView 并 bind()
##   UnitView._process         → 自己从 Unit 读 position / forward 插值（表现层拉，不推）
##
## 单位位置**不**由本文件每帧擦写：UnitView 自己只读跟踪（硬规则 4），
## 本文件只把新单位与视图绑一次。想加"看起来该动一下"的效果，加在 UnitView 里。
##
## 相机由 scenes/camera/rts_camera.tscn 实例化，上层只通过 view_projection() 取投影，
## 因此不知道当前是 2D 还是 3D（ADR-0001）。

# ---------------------------------------------------------------- 地图（逻辑 ID，不是路径）
#
# T-2.0 起地图内容（障碍 / 初始单位 / 天空 / 进场机位）全部在
# content/maps/<id>/map.tbl，本文件只剩一个**逻辑 ID**（= content/maps 下的目录名）。
# 硬规则 5 的同一条逻辑：代码不写资产名、不写坐标，只写逻辑 ID。
# 换地图 = 改这一行（S3 会改成关卡选择 / 命令行参数）。
const MAP_ID := "skirmish"

## 路径线的颜色（L2 表现层，纯视觉，不参与模拟）
const ROUTE_COLOR := Color(0.45, 1.0, 0.65, 1.0)
## 膨胀圈外壳颜色（告诉眼睛"导航实际避让到哪"）
const INFLATED_COLOR := Color(0.35, 0.75, 1.0, 0.10)

@export var unit_scene: PackedScene

@onready var world: Node3D = $World
@onready var units: Node3D = $Units
@onready var camera_rig: RtsCameraRig = $Camera
@onready var input_router: InputRouter = $InputRouter
@onready var _hud: MinimalHUD = $HudLayer/MinimalHUD
@onready var _projectiles_fx: ProjectileField = $ProjectileField
@onready var _fx_root: Node3D = $FxRoot

## 模拟中枢（RefCounted：不占节点、可无头单测）
var _session: BattleSession = null
## 最小交战 AI（S4 前的占位实现）：只驱动敌方队伍，否则主场景里两支舰队一直对望
var _ai: SimpleAI = null
## AI 控制的队伍号（玩家指挥 0）
const AI_TEAM := 1
## 本局地图数据（L0，来自 Registry.map(MAP_ID)；加载失败时为 null，世界为空）
var _map: MapDef = null
## unit.id → UnitView（表现层索引，仅本文件持有）
var _views: Dictionary = {}

var _route_mesh := ImmediateMesh.new()
var _route_instance: MeshInstance3D = null
## 画膨胀圈用的代表半径（取本局最大的单位半径）
var _visual_unit_radius := 0.0


func _ready() -> void:
	assert(world != null, "Battle 缺少 World 容器")
	assert(units != null, "Battle 缺少 Units 容器")
	assert(camera_rig != null, "Battle 缺少 Camera（RtsCameraRig）")
	assert(input_router != null, "Battle 缺少 InputRouter")

	# 依赖注入，不在 InputRouter 里写死节点路径
	input_router.setup(camera_rig, camera_rig.view_projection())
	# 右键命令菜单（旧版 show_context_menu 的等价物）。
	# 注入后就改成“右键弹菜单、选完再下令”；不注入则保持右键直接下令。
	var menu := get_node_or_null(^"HudLayer/CommandMenu")
	if menu != null:
		input_router.set_command_menu(menu)
	# 暂停（Space，与旧版一致）：输入层只发信号，真正改 Simulation 在这里做。
	if not input_router.pause_toggled.is_connected(_on_pause_toggled):
		input_router.pause_toggled.connect(_on_pause_toggled)

	# 地图先加载：天空 / 障碍 / 单位 / 进场机位全从它来（L0 → 本文件只做接线）
	_load_map()

	_setup_environment()
	_setup_route_gizmo()

	# 模拟中枢：数据层 + 命令入口由外部注入（Battle 不自己 new Registry）
	_session = BattleSession.new()
	_session.setup(GameState.registry(), CommandBus)
	_session.unit_spawned.connect(_on_unit_spawned)
	_session.unit_died.connect(_on_unit_died)
	_session.route_assigned.connect(_on_route_assigned)
	_session.command_applied.connect(_on_command_applied)

	# 先建单位：障碍的膨胀圈外壳要按本局最大单位半径来画（_visual_unit_radius）
	_spawn_units()
	_build_map()

	# 选择候选 = Unit 数据对象（ViewProjection 认 position 属性），
	# 于是选中列表里拿到的是模拟对象本身，CommandBus 的目标也就直接是 Unit。
	input_router.set_candidates(_session.units())

	# HUD 只是只读表现层：它自己每帧从 session 读 position / team / hp_ratio()。
	# 不反向写任何模拟字段（硬规则 4）。
	if _hud != null:
		_hud.bind_session(_session)
	# 弹道表现层：每帧从 ProjectileManager 读弹体位置重建 MultiMesh（只读）
	if _projectiles_fx != null:
		_projectiles_fx.bind_session(_session)

	# 最小交战 AI：只控敌方（team 1）。玩家指挥 team 0。
	# 没有它的话，不给命令就永远不会打起来 —— S3 结束时的真实状态。
	_ai = SimpleAI.new(AI_TEAM)

	# 单一更新驱动：Simulation 每 tick 发一次，本文件只转发给 session（硬规则 2）
	if not Simulation.ticked.is_connected(_on_ticked):
		Simulation.ticked.connect(_on_ticked)

	# 进场机位（相机只是镜头，不写模拟状态）
	if _map != null:
		camera_rig.focus_on(_map.focus, true)
		camera_rig.camera_3d.zoom_to(_map.camera_distance, true)

	# 机型数据完整性：缺键 = 坏数据，对应单位不会被生成（见 UnitDef）
	var missing := _session.data_warnings()
	if not missing.is_empty():
		push_error("[battle] 以下机型有必需键缺失，对应单位未能生成：%s" % str(missing))
	print("[battle] 装配完成：地图 %s，单位 %d，障碍 %d，层级 %s" % [
		"(未加载)" if _map == null else _map.id,
		_session.unit_count(), _session.obstacle_count(),
		"(未加载)" if _map == null else "L%d/%+.0f m" % [
			_map.layer_default, MapDef.layer_center(_map.layer_default)]])
	print("[battle] 机型数据来源：%s" % (
		"全部必需键来自 unit.tbl" if missing.is_empty() else str(missing)))


func _exit_tree() -> void:
	if Simulation.ticked.is_connected(_on_ticked):
		Simulation.ticked.disconnect(_on_ticked)
	if _session != null:
		_session.shutdown()
		_session = null


## 模拟中枢（验证场景 / 调试面板用；游戏本体不该越过本文件操作它）
func session() -> BattleSession:
	return _session


# ---------------------------------------------------------------- 地图装配


## 从 Registry 读地图：逻辑 ID → 记录 → MapDef（解析 + 校验）。
## 坏数据不静默降级：Registry / MapDef 会逐条 push_error，这里只负责汇报；
## _map 保持 null 时世界是空的（不拿旧常量兜底）。
func _load_map() -> void:
	var registry := GameState.registry()
	if registry == null:
		push_error("[battle] GameState.registry() 为空，地图 '%s' 无法加载" % MAP_ID)
		return
	var record := registry.map(MAP_ID)  # 未知 ID 时 Registry 已 push_error
	if record.is_empty():
		return
	_map = MapDef.from_record(MAP_ID, record, registry)
	if not _map.is_valid():
		push_error("[battle] 地图 '%s' 有 %d 处数据错误，放弃装配（详见上方的 [MapDef] 报错）" % [
			MAP_ID, _map.errors.size()])
		_map = null
		return
	for line in _map.warnings:
		push_warning("[battle] 地图 '%s' %s" % [MAP_ID, line])


func _build_map() -> void:
	if _map == null:
		return
	# 本局的默认高度层来自地图（ADR-0003）；逐单位切层指令归 S2
	_session.set_layer_height(MapDef.layer_center(_map.layer_default))
	for entry in _map.obstacles:
		var obstacle := NavObstacle.new(
			entry.position, entry.radius, entry.top_y, entry.bottom_y)
		if not obstacle.is_valid():
			push_error("[battle] 障碍 %s 不自洽，跳过：%s" % [entry.name, obstacle.describe()])
			continue
		_session.add_obstacle(obstacle)
		_build_obstacle_visual(obstacle)


## 障碍的可视外壳 + 膨胀圈外壳（纯表现，数值只从 NavObstacle 读，不另存一份）
func _build_obstacle_visual(obstacle: NavObstacle) -> void:
	var height := maxf(obstacle.top_y - obstacle.bottom_y, 1.0)
	var center_y := (obstacle.top_y + obstacle.bottom_y) * 0.5

	var rock := MeshInstance3D.new()
	rock.name = "Obstacle"
	rock.mesh = _cylinder(obstacle.radius_xz, height)
	rock.position = Vector3(obstacle.position.x, center_y, obstacle.position.z)
	rock.material_override = _simple_material(Color(0.30, 0.29, 0.33), false)
	world.add_child(rock)

	# 膨胀圈 = 障碍 r + 单位 r + 安全余量（与 NavObstacle.inflated_radius 同源）
	var inflated := obstacle.inflated_radius(maxf(_visual_unit_radius, 0.0))
	var shell := MeshInstance3D.new()
	shell.name = "Inflated"
	shell.mesh = _cylinder(inflated, height)
	shell.position = rock.position
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.material_override = _simple_material(INFLATED_COLOR, true)
	world.add_child(shell)


func _cylinder(radius: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = maxf(radius, 0.01)
	mesh.bottom_radius = maxf(radius, 0.01)
	mesh.height = maxf(height, 0.01)
	mesh.radial_segments = 24
	mesh.rings = 1
	return mesh


func _simple_material(color: Color, transparent: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = (BaseMaterial3D.SHADING_MODE_UNSHADED
		if transparent else BaseMaterial3D.SHADING_MODE_PER_PIXEL)
	if transparent:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


# ---------------------------------------------------------------- 单位


func _spawn_units() -> void:
	if _map == null:
		return
	for entry in _map.spawns:
		var def_id := entry.unit_id
		# 队伍号来自地图表（[spawn.<名字>] team），BattleSession 按它自动分编队
		var unit := _session.spawn_unit(def_id, entry.position, entry.team)
		if unit == null:
			push_error("[battle] 单位 '%s' 生成失败（见上方 Registry 报错）" % def_id)
			continue
		_visual_unit_radius = maxf(_visual_unit_radius, unit.radius)


## 新单位 → 挂一个 unit_base.tscn 的 UnitView 并绑定（表现层只读，硬规则 4）
func _on_unit_spawned(unit: Unit) -> void:
	if unit_scene == null or not unit_scene.can_instantiate():
		push_error("[battle] unit_scene 未指定或不可实例化，单位 %d 只有数据没有表现" % unit.id)
		return
	var view := unit_scene.instantiate() as UnitView
	if view == null:
		push_error("[battle] unit_scene 的根节点不是 UnitView")
		return
	view.name = "Unit_%d" % unit.id
	units.add_child(view)
	view.bind(unit)
	if not view.apply_model_from_registry():
		# 模型缺失不是致命错误：占位 BoxMesh 仍然能表达位置与朝向
		push_warning("[battle] 单位 %d（%s）没有挂上真实模型，使用占位盒" % [unit.id, unit.def_id])
	_views[unit.id] = view


## 某单位的表现节点（验证场景 / 调试可视化用；没有则 null）
func unit_view(unit_id: int) -> UnitView:
	return _views.get(unit_id, null) as UnitView


## 单位阵亡 → **释掉表现节点**。
##
## 之前漏了这条接线：模拟层已经正常销毁了单位（_units 里没了、统计也对），
## 但 UnitView 没人释放，于是被打死的敌**模型还留在场上**——玩家看到的就是
## “敌人已经爆了，但模型仍在飞”甚至参与后续观感。
## 这是漏接线，不是“没做到”：_settle_kills 早就发了 unit_died，只是没人听。
func _on_unit_died(unit: Unit, _killer_id: int) -> void:
	if unit == null:
		return
	# 退场爆炸：在单位**最后的位置**炸一团（尺寸随舰体缩放）
	if _fx_root != null and unit.position.is_finite():
		var burst := DeathBurst.new()
		_fx_root.add_child(burst)
		var tint := Color(1.0, 0.55, 0.35) if unit.team == 1 else Color(0.35, 0.95, 1.0)
		burst.setup(unit.position, unit.radius, tint)

	var view: UnitView = _views.get(unit.id, null) as UnitView
	_views.erase(unit.id)
	if view != null:
		# 立刻从树上摘掉：queue_free 要到帧末才生效，同一帧里还可能被框选/渲染到
		if view.get_parent() != null:
			view.get_parent().remove_child(view)
		view.queue_free()
	# 死人的航线不该还画在场上
	_rebuild_route_mesh()


# ---------------------------------------------------------------- 每 tick 接线


## Simulation 的固定步长 → 会话推进。表现层不用在这里推：
## UnitView 自己每帧从 Unit 读 position / forward 做指数插值（只读，硬规则 4）。
func _on_ticked(_tick_index: int) -> void:
	if _session == null:
		return
	# AI 先下令、再推进：命令入队后由 tick 第 1 步统一执行（硬规则 2），
	# 于是 AI 与玩家命令走完全相同的路径与时序，不存在两条更新链路。
	if _ai != null:
		_ai.tick(_session, Simulation.TICK_SECONDS)
	_session.tick(Simulation.TICK_SECONDS)


func _on_route_assigned(_unit: Unit, _path: PackedVector3Array) -> void:
	_rebuild_route_mesh()


func _on_command_applied(_kind: StringName, _count: int) -> void:
	_rebuild_route_mesh()


func _on_pause_toggled() -> void:
	Simulation.toggle_pause()


# ---------------------------------------------------------------- 路径线（L2，只读模拟）


func _setup_route_gizmo() -> void:
	_route_instance = MeshInstance3D.new()
	_route_instance.name = "Routes"
	_route_instance.mesh = _route_mesh
	_route_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 走正常深度测试：路径线被障碍遮住才看得出"线是绕过去的"，
	# 画在障碍上面（no_depth_test）会变成"线穿模"的错觉。调试用叠加层以后另开一层。
	_route_instance.material_override = _simple_material(ROUTE_COLOR, false)
	_route_instance.visible = false
	world.add_child(_route_instance)


## 把所有单位的 route 画成折线（只读 unit.route，一个字段都不写）
func _rebuild_route_mesh() -> void:
	if _route_instance == null or _session == null:
		return
	_route_mesh.clear_surfaces()
	var drew := false
	for unit in _session.units():
		if unit.route.is_empty():
			continue
		_route_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for point in unit.route:
			_route_mesh.surface_add_vertex(point)
		_route_mesh.surface_end()
		drew = true
	_route_instance.visible = drew


# ---------------------------------------------------------------- 环境（纯表现）


## 天空 + 环境光 + 一盏方向光。天空贴图走 Registry（硬规则 5），逻辑名来自地图的 [map] sky。
func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 1.0
	var sky := Sky.new()
	var material := PanoramaSkyMaterial.new()
	var texture := _load_sky_texture()
	if texture != null:
		material.panorama = texture
	else:
		push_warning("[battle] 天空贴图未加载到，使用无全景的天空资源")
	sky.sky_material = material
	env.sky = sky

	var world_env := WorldEnvironment.new()
	world_env.name = "Environment"
	world_env.environment = env
	world.add_child(world_env)

	var light := DirectionalLight3D.new()
	light.name = "KeyLight"
	light.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	light.light_energy = 1.2
	world.add_child(light)


## 注册表给的是**不带扩展名**的路径，这里补 .png 再 load（与 UnitView 同一约定）
func _load_sky_texture() -> Texture2D:
	var registry := GameState.registry()
	if registry == null:
		return null
	if _map == null or _map.sky.is_empty():
		return null
	var path := registry.asset(_map.sky)
	if path.strip_edges().is_empty():
		return null
	var candidate := "%s.png" % path
	if not ResourceLoader.exists(candidate, "Texture2D"):
		push_warning("[battle] 天空贴图不存在：%s" % candidate)
		return null
	return ResourceLoader.load(candidate, "Texture2D") as Texture2D
