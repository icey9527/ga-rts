extends Node3D

## 资产验证场景（开发期工具，不属于游戏主流程）。
##
## 作用：把 assets/models/ships 下的全部舰船按真实尺寸排成一行，配上烘焙天空，
## 自动截图两张后退出。用于确认模型的尺寸、朝向、材质、LOD 是否正确。
##
## 运行：
##     Godot_v4.7.2-stable_win64_console.exe --path F:/godot/ga-rts \
##         scenes/dev/verify_assets.tscn
##
## 产物：
##     tools/temp/verify_overview.png   全体相对尺寸总览
##     tools/temp/verify_closeup.png    中小型舰特写（看材质与朝向）

const SHIP_DIR := "res://assets/models/ships"
const SKY_PATH := "res://assets/sky/si_sbg_0110.png"
const OVERVIEW_PATH := "res://tools/temp/verify_overview.png"
const CLOSEUP_PATH := "res://tools/temp/verify_closeup.png"
const CLOSEUP_COUNT := 3

## 舰船之间的空隙，相对于前一艘舰的尺寸
@export var gap_ratio := 0.6
## 总览截图前的等待帧数，让渲染与资源加载完成
@export var warmup_frames := 6

var _ships: Array[Node3D] = []
var _row_box := AABB()
var _camera: Camera3D
var _frames := 0
var _stage := 0


func _ready() -> void:
	_setup_environment()
	_setup_camera()
	_spawn_ships()
	_frame_overview()


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < warmup_frames:
		return
	_frames = 0
	match _stage:
		0:
			# 必须先等截图真正写完再换镜头，否则总览图会拍到特写的机位
			await _save_shot(OVERVIEW_PATH)
			_stage = 1
			_frame_closeup()
		1:
			await _save_shot(CLOSEUP_PATH)
			_stage = 2
			print("[verify] 截图完成，退出")
			get_tree().quit()


func _setup_environment() -> void:
	var env := Environment.new()
	var sky := Sky.new()
	var sky_mat := PanoramaSkyMaterial.new()
	var sky_tex := load(SKY_PATH) as Texture2D
	if sky_tex == null:
		push_error("[verify] 天空贴图加载失败: %s" % SKY_PATH)
	else:
		sky_mat.panorama = sky_tex
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0

	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-35.0, 45.0, 0.0)
	sun.light_energy = 1.2
	add_child(sun)


func _setup_camera() -> void:
	_camera = Camera3D.new()
	_camera.near = 0.5
	_camera.far = 500000.0
	_camera.fov = 50.0
	add_child(_camera)
	_camera.current = true


func _spawn_ships() -> void:
	var dir := DirAccess.open(SHIP_DIR)
	if dir == null:
		push_error("[verify] 打不开目录: %s" % SHIP_DIR)
		return

	var ids: Array[String] = []
	for sub in dir.get_directories():
		ids.append(sub)
	ids.sort()

	var cursor := 0.0
	var report: Array[String] = []
	for id in ids:
		var path := "%s/%s/%s.glb" % [SHIP_DIR, id, id]
		if not ResourceLoader.exists(path):
			push_warning("[verify] 缺文件: %s" % path)
			continue
		var packed := load(path) as PackedScene
		if packed == null:
			push_error("[verify] 加载失败: %s" % path)
			continue

		var ship := packed.instantiate() as Node3D
		add_child(ship)
		var box := _world_box(ship)
		var size := box.size
		var radius := maxf(maxf(size.x, size.y), size.z)
		if radius <= 0.0:
			radius = 1.0

		# 沿 +X 依次摆放，间距取自身尺寸，保持真实相对比例
		cursor += radius * 0.5
		ship.position.x = cursor - box.position.x
		cursor += radius * 0.5 + radius * gap_ratio

		_ships.append(ship)
		report.append("%-8s 尺寸 %8.1f x %8.1f x %8.1f" % [id, size.x, size.y, size.z])

		_row_box = _world_box(ship) if _ships.size() == 1 else _row_box.merge(_world_box(ship))

	print("[verify] 载入 %d 艘舰船" % _ships.size())
	for line in report:
		print("[verify]   " + line)
	print("[verify] 整行包围盒 尺寸 %.1f x %.1f x %.1f" % [
		_row_box.size.x, _row_box.size.y, _row_box.size.z])


func _world_box(node: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi := child as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = mi.global_transform * mi.get_aabb()
		merged = box if first else merged.merge(box)
		first = false
	if first:
		return AABB(node.global_position, Vector3.ONE)
	return merged


func _frame_overview() -> void:
	if _ships.is_empty():
		return
	var center := _row_box.get_center()
	var span := maxf(_row_box.size.x, 1.0)
	# 按相机实际视场算距离，否则固定倍数会拍得太远看不清
	var aspect := 16.0 / 9.0
	var vp := get_viewport().get_visible_rect().size
	if vp.y > 0.0:
		aspect = vp.x / vp.y
	var half_h_fov := atan(tan(deg_to_rad(_camera.fov) * 0.5) * aspect)
	var dist := (span * 0.5) / maxf(tan(half_h_fov), 0.01)
	_camera.position = center + Vector3(0.0, span * 0.10, dist)
	_camera.look_at(center, Vector3.UP)


func _frame_closeup() -> void:
	var targets: Array[Node3D] = []
	for i in mini(CLOSEUP_COUNT, _ships.size()):
		targets.append(_ships[i])
	if targets.is_empty():
		return
	var box := _world_box(targets[0])
	for i in range(1, targets.size()):
		box = box.merge(_world_box(targets[i]))
	var center := box.get_center()
	var radius := maxf(maxf(box.size.x, box.size.y), box.size.z)
	_camera.position = center + Vector3(radius * 0.25, radius * 0.30, radius * 0.85)
	_camera.look_at(center, Vector3.UP)


func _save_shot(res_path: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("[verify] 截图为空")
		return
	var abs_path := ProjectSettings.globalize_path(res_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("[verify] 保存截图失败 %s (err=%d)" % [abs_path, err])
	else:
		print("[verify] 已保存 %s" % abs_path)
