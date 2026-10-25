extends Node3D

## 可视化验收场景（T-1.6 的视觉产物，**有渲染**，不是无头测试）。
##
## 跑法（不要 --headless，否则截不到图）：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --path F:\godot\ga-rts \
##         scenes/dev/view_slice.tscn
##
## 它做的事：
##   1. 实例化真正的战斗场景（scenes/battle/battle.tscn，走 @export 注入，不写路径）
##   2. 用 InputRouter 的公开入口选中 1 艘船，经 CommandBus 发 cmd_move（与右键点击同一条路）
##   3. 等它沿导航绕过 3 个障碍抵达（Engine.time_scale 加速，不然要等 40 s）
##   4. 截图：3D 机位一张、切到 2D 正交一张 → res://tools/temp/
##   5. 打印抵达误差 / 路径 / 截图体积，quit(0)
##
## 为什么不在这个脚本里合成鼠标事件：
##   输入层（InputRouter 的 点击 → 选择 → CommandBus）已在 T-1.3 的 verify_input.tscn 里
##   逐条验证过；这里要验收的是"模拟 + 表现 + 相机"的合成结果。
##   选中走 set_selection()、命令走 CommandBus.issue()，正是 InputRouter 右键处理器的两行。

@export var battle_scene: PackedScene

## 输出目录 / 文件名（不是资源路径：这是运行时产物，落在就地目录）
const SHOT_DIR := "res://tools/temp"
const SHOT_3D_FILE := "slice_shot.png"
const SHOT_2D_FILE := "slice_shot_2d.png"

## 演示用的目标点（世界坐标，米）——与 battle.gd 的地图内容配套
const DEMO_TARGET := Vector3(3200.0, 0.0, 200.0)
## 用哪艘船演示（机型逻辑 ID，不是路径）。选 80 m 级的护卫舰：
## 320 m/s 的小艇在这个机位下只有几像素，截图上分不清是船还是噪点。
const DEMO_DEF_ID := "ou134"
## 时间倍率：只影响观察速度，不影响模拟步长（Simulation 仍是固定 60 Hz）
const TIME_SCALE := 4.0
## 等待抵达的墙钟上限（秒）
const MAX_WAIT_SECONDS := 90.0

var _battle: Node3D = null
var _session: BattleSession = null
var _unit: Unit = null
## 3D 近景里单位的屏幕坐标（打印 "两种镜头同源" 时用）
var _screen_3d := Vector2.ZERO


func _ready() -> void:
	Engine.time_scale = TIME_SCALE
	print("[view] time_scale = %.1f" % TIME_SCALE)

	if battle_scene == null or not battle_scene.can_instantiate():
		push_error("[view] battle_scene 未注入（.tscn 的 @export），无法演示")
		get_tree().quit(1)
		return
	_battle = battle_scene.instantiate() as Node3D
	if _battle == null:
		push_error("[view] battle_scene 根节点不是 Node3D")
		get_tree().quit(1)
		return
	add_child(_battle)
	await get_tree().process_frame
	await get_tree().process_frame

	_session = _battle.call(&"session") as BattleSession
	if _session == null:
		push_error("[view] 战斗场景没有 session()，接线不对")
		get_tree().quit(1)
		return
	_unit = _find_unit(DEMO_DEF_ID)
	if _unit == null:
		push_error("[view] 战斗场景里没有机型 %s" % DEMO_DEF_ID)
		get_tree().quit(1)
		return

	_mark_target(DEMO_TARGET)
	await _run_demo()
	await _capture_shot()
	get_tree().quit(0)


## 选中 → 命令（与 InputRouter._handle_right_click → _issue 同一条链）
func _run_demo() -> void:
	var router := _battle.get_node_or_null(^"InputRouter") as InputRouter
	if router == null:
		push_error("[view] 战斗场景缺少 InputRouter")
		return
	router.set_selection([_unit])
	print("[view] 选中 %s（%s）" % [_unit.def_id, _unit.describe()])
	var issued := CommandBus.issue(router.selection(), BattleSession.CMD_MOVE,
		{"point": DEMO_TARGET, "source": &"view_slice"})
	print("[view] CommandBus.issue(cmd_move) → %s，目标 %s" % [
		str(issued), _short(DEMO_TARGET)])

	# 等抵达（按墙钟计时；time_scale 只缩短等待，不改模拟步长）
	var started := Time.get_ticks_msec()
	var budget_ms := int(MAX_WAIT_SECONDS * 1000.0)
	while not _unit.is_route_finished():
		await get_tree().physics_frame
		if Time.get_ticks_msec() - started > budget_ms:
			push_warning("[view] %.0f s 内没有抵达，按当前状态截图" % MAX_WAIT_SECONDS)
			break

	# 让 UnitView 的指数插值追上来（它按渲染帧收敛，模拟已经停了）
	for _i in 20:
		await get_tree().process_frame

	var error := _unit.position.distance_to(DEMO_TARGET)
	print("[view] 抵达：位置 %s，误差 %.3f m，tick=%d，用时 %.1f s（墙钟）" % [
		_short(_unit.position), error, _session.stats()["ticks"],
		float(Time.get_ticks_msec() - started) / 1000.0])
	print("[view] 路径 %d 点：%s" % [_unit.route.size(), _path_text(_unit.route)])
	print("[view] stats=%s" % str(_session.stats()))


## 3D 近景 + 2D 总览，落盘后打印绝对路径与体积
##
## 两张图都是**验收证据**，不是美术截图：
##   3D 近景：抵达的船 + 它刚绕过的障碍（含膨胀圈外壳）+ 路径末段 + 目标标记
##   2D 总览：整张地图的俯视 —— 3 个障碍 + 完整路径 + 两艘船，证明 2D 是镜头不是第二套模拟
func _capture_shot() -> void:
	var rig := _battle.get_node_or_null(^"Camera") as RtsCameraRig
	if rig == null:
		push_error("[view] 战斗场景缺少 Camera")
		return

	# 近景：焦点放在"船 → 最近障碍"的连线上，机位压近到能看清船体与膨胀圈的相对关系
	var nearest := _nearest_obstacle(_unit.position)
	var focus := _unit.position
	if nearest != null:
		var rim := Vector3(nearest.position.x, _unit.position.y, nearest.position.z)
		focus = _unit.position.lerp(rim, 0.42)
	rig.focus_on(focus, true)
	rig.camera_3d.zoom_to(1600.0, true)
	rig.camera_3d.set_pitch_degrees(-34.0)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[view] 3D 近景焦点 %s（最近障碍 %s）" % [
		_short(focus), "无" if nearest == null else nearest.describe()])
	_screen_3d = rig.view_projection().world_to_screen(_unit.position)
	await _save(SHOT_3D_FILE)

	# 2D 总览：正交相机有自己的 size，必须在 2D 模式下单独设
	rig.toggle_mode()
	rig.camera_2d.zoom_to(_map_extent() * 1.2, true)
	rig.focus_on(_map_center(), true)
	# 全景天空在正俯视时会退化成一圈拉伸的星芒（等距柱面投影的极点），
	# 换纯色背景才能看清地图。S2 做 2D 天空方案时一并处理。
	_use_flat_background()
	await get_tree().process_frame
	await get_tree().process_frame
	_print_consistency(rig)
	await _save(SHOT_2D_FILE)


## 顺手把"同一份世界坐标 → 两个镜头两个屏幕坐标"打出来。
## 像素不同是镜头差异（透视 vs 正交），世界坐标相同才是硬规则 7（2D 是镜头不是第二套模拟）。
func _print_consistency(rig: RtsCameraRig) -> void:
	var projection := rig.view_projection()
	if not projection.is_ready():
		return
	var screen_2d := projection.world_to_screen(_unit.position)
	print("[view] 单位世界坐标 %s：3D 屏幕 %s / 2D 屏幕 %s（像素不同 = 镜头不同）" % [
		_short(_unit.position), str(_screen_3d), str(screen_2d)])


func _save(file_name: String) -> void:
	var directory := ProjectSettings.globalize_path(SHOT_DIR)
	var err_dir := DirAccess.make_dir_recursive_absolute(directory)
	if err_dir != OK and err_dir != ERR_ALREADY_EXISTS:
		push_error("[view] 无法创建截图目录 %s（err=%d）" % [directory, err_dir])
		return
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("[view] 取不到 viewport 图像（是不是在 --headless 下跑的？）")
		return
	var path := directory.path_join(file_name)
	var err := image.save_png(path)
	if err != OK:
		push_error("[view] 存图失败 %s（err=%d）" % [path, err])
		return
	var bytes := 0
	var file := FileAccess.open(path, FileAccess.READ)
	if file != null:
		bytes = file.get_length()
		file.close()
	print("[view] 截图 %s（%d×%d，%d 字节 = %.1f KiB）" % [
		path, image.get_width(), image.get_height(), bytes, float(bytes) / 1024.0])


## 目标点标记（纯表现，自建 mesh，不引任何资源）
func _mark_target(point: Vector3) -> void:
	var world := _battle.get_node_or_null(^"World") as Node3D
	if world == null:
		return
	var marker := MeshInstance3D.new()
	marker.name = "DemoTarget"
	var sphere := SphereMesh.new()
	sphere.radius = 45.0
	sphere.height = 90.0
	sphere.radial_segments = 16
	sphere.rings = 8
	marker.mesh = sphere
	# 浮标悬在落点上方 120 m：落在原点位会正好挡住抵达的船体
	marker.position = point + Vector3(0.0, 120.0, 0.0)
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.85, 0.3, 1.0)
	material.no_depth_test = true
	marker.material_override = material
	world.add_child(marker)


## 离某点最近的障碍（XZ 距离）。近景机位用它构图，不复制地图数据。
func _nearest_obstacle(point: Vector3) -> NavObstacle:
	var best: NavObstacle = null
	var best_distance := INF
	for obstacle in _session.obstacles():
		var dx := obstacle.position.x - point.x
		var dz := obstacle.position.z - point.z
		var distance := dx * dx + dz * dz
		if distance < best_distance:
			best_distance = distance
			best = obstacle
	return best


## 地图内容（船 + 障碍）的 XZ 中心 / 半径，用于 2D 总览构图
func _map_center() -> Vector3:
	var min_xz := Vector2(INF, INF)
	var max_xz := Vector2(-INF, -INF)
	for unit in _session.units():
		min_xz = min_xz.min(Vector2(unit.position.x, unit.position.z))
		max_xz = max_xz.max(Vector2(unit.position.x, unit.position.z))
	for obstacle in _session.obstacles():
		min_xz = min_xz.min(Vector2(obstacle.position.x, obstacle.position.z) - Vector2.ONE * obstacle.radius_xz)
		max_xz = max_xz.max(Vector2(obstacle.position.x, obstacle.position.z) + Vector2.ONE * obstacle.radius_xz)
	var center := (min_xz + max_xz) * 0.5
	return Vector3(center.x, 0.0, center.y)


func _map_extent() -> float:
	var center := _map_center()
	var extent := 0.0
	for unit in _session.units():
		extent = maxf(extent, Vector2(unit.position.x - center.x, unit.position.z - center.z).length())
	for obstacle in _session.obstacles():
		extent = maxf(extent, Vector2(obstacle.position.x - center.x, obstacle.position.z - center.z).length() + obstacle.radius_xz)
	return maxf(extent, 1000.0)


## 切纯色背景（仅 2D 截图用，见 _capture_shot 里的原因）
func _use_flat_background() -> void:
	var world := _battle.get_node_or_null(^"World") as Node3D
	if world == null:
		return
	var world_env := world.get_node_or_null(^"Environment") as WorldEnvironment
	if world_env == null or world_env.environment == null:
		return
	world_env.environment.background_mode = Environment.BG_COLOR
	world_env.environment.background_color = Color(0.02, 0.03, 0.06, 1.0)
	world_env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_env.environment.ambient_light_color = Color(0.45, 0.5, 0.62)
	world_env.environment.ambient_light_energy = 0.9


func _find_unit(def_id: String) -> Unit:
	for unit in _session.units():
		if unit.def_id == def_id:
			return unit
	return null


func _short(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _path_text(path: PackedVector3Array) -> String:
	if path.is_empty():
		return "(空)"
	var parts := PackedStringArray()
	for point in path:
		parts.append(_short(point))
	return " → ".join(parts)
