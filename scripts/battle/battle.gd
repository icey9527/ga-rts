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

# ---------------------------------------------------------------- 地图内容（本卡）
#
# TODO(S2)：改从地图 TBL 读（content/maps/<id>/map.tbl 的 [terrain] / [spawn] 节）。
# 现在写在本文件顶部是因为 S1 还没有地形数据格式；**不要**把这些数字散到函数里。

## 障碍：NavObstacle 的 (圆心 XZ, XZ 半径, 柱顶, 柱底)。
## 尺寸参考 docs/scale-and-units.md：小行星 / 空间站 50~800 m。
## 云图说明（让右下的船必须绕行）：
##   A 挡在起终点连线附近、B 更靠右、C 偏北纯装饰（不挡直飞，用来验证高度过滤/视觉层次）。
const MAP_OBSTACLES := [
	{"position": Vector3(-400.0, 0.0, -100.0), "radius_xz": 320.0, "top_y": 400.0, "bottom_y": -200.0},
	{"position": Vector3(1200.0, 0.0, 250.0), "radius_xz": 380.0, "top_y": 500.0, "bottom_y": -300.0},
	{"position": Vector3(-1800.0, 0.0, 900.0), "radius_xz": 240.0, "top_y": 300.0, "bottom_y": -300.0},
]

## 单位：机型逻辑 ID + 生成位置（世界坐标，米）。机型数据全部走 Registry（硬规则 5）。
const MAP_SHIPS := [
	{"def_id": "ou134", "position": Vector3(-3000.0, 0.0, 0.0)},
	{"def_id": "ou05", "position": Vector3(-3000.0, 0.0, 1400.0)},
]

## 进场机位：焦点放在战场中心，距离够看到起点与障碍。
const OVERVIEW_FOCUS := Vector3(-200.0, 0.0, 300.0)
const OVERVIEW_DISTANCE := 7000.0

## 天空逻辑名（assets.tbl 的 [sky] 节）。S2 改由地图数据指定。
const SKY_LOGICAL_NAME := "si_sbg_0110"

## 路径线的颜色（L2 表现层，纯视觉，不参与模拟）
const ROUTE_COLOR := Color(0.45, 1.0, 0.65, 1.0)
## 膨胀圈外壳颜色（告诉眼睛"导航实际避让到哪"）
const INFLATED_COLOR := Color(0.35, 0.75, 1.0, 0.10)

@export var unit_scene: PackedScene

@onready var world: Node3D = $World
@onready var units: Node3D = $Units
@onready var camera_rig: RtsCameraRig = $Camera
@onready var input_router: InputRouter = $InputRouter

## 模拟中枢（RefCounted：不占节点、可无头单测）
var _session: BattleSession = null
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

	_setup_environment()
	_setup_route_gizmo()

	# 模拟中枢：数据层 + 命令入口由外部注入（Battle 不自己 new Registry）
	_session = BattleSession.new()
	_session.setup(GameState.registry(), CommandBus)
	_session.unit_spawned.connect(_on_unit_spawned)
	_session.route_assigned.connect(_on_route_assigned)
	_session.command_applied.connect(_on_command_applied)

	# 先建单位：障碍的膨胀圈外壳要按本局最大单位半径来画（_visual_unit_radius）
	_spawn_units()
	_build_map()

	# 选择候选 = Unit 数据对象（ViewProjection 认 position 属性），
	# 于是选中列表里拿到的是模拟对象本身，CommandBus 的目标也就直接是 Unit。
	input_router.set_candidates(_session.units())

	# 单一更新驱动：Simulation 每 tick 发一次，本文件只转发给 session（硬规则 2）
	if not Simulation.ticked.is_connected(_on_ticked):
		Simulation.ticked.connect(_on_ticked)

	# 进场机位（相机只是镜头，不写模拟状态）
	camera_rig.focus_on(OVERVIEW_FOCUS, true)
	camera_rig.camera_3d.zoom_to(OVERVIEW_DISTANCE, true)

	print("[battle] 装配完成：单位 %d，障碍 %d，机型数据缺键 %s" % [
		_session.unit_count(), _session.obstacle_count(),
		"无" if _session.data_warnings().is_empty() else str(_session.data_warnings())])


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


func _build_map() -> void:
	for entry in MAP_OBSTACLES:
		var obstacle := NavObstacle.new(
			entry["position"], entry["radius_xz"], entry["top_y"], entry["bottom_y"])
		if not obstacle.is_valid():
			push_error("[battle] 障碍数据不自洽，跳过：%s" % obstacle.describe())
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
	for entry in MAP_SHIPS:
		var def_id := str(entry["def_id"])
		var unit := _session.spawn_unit(def_id, entry["position"])
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


# ---------------------------------------------------------------- 每 tick 接线


## Simulation 的固定步长 → 会话推进。表现层不用在这里推：
## UnitView 自己每帧从 Unit 读 position / forward 做指数插值（只读，硬规则 4）。
func _on_ticked(_tick_index: int) -> void:
	if _session == null:
		return
	_session.tick(Simulation.TICK_SECONDS)


func _on_route_assigned(_unit: Unit, _path: PackedVector3Array) -> void:
	_rebuild_route_mesh()


func _on_command_applied(_kind: StringName, _count: int) -> void:
	_rebuild_route_mesh()


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


## 天空 + 环境光 + 一盏方向光。天空贴图走 Registry（硬规则 5），逻辑名见 SKY_LOGICAL_NAME。
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
	var path := registry.asset(SKY_LOGICAL_NAME)
	if path.strip_edges().is_empty():
		return null
	var candidate := "%s.png" % path
	if not ResourceLoader.exists(candidate, "Texture2D"):
		push_warning("[battle] 天空贴图不存在：%s" % candidate)
		return null
	return ResourceLoader.load(candidate, "Texture2D") as Texture2D
