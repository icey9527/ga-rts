extends Node3D

## 动态诊断：把真实 battle.tscn 装进来，逐帧记录
##   模拟层 unit.forward  vs  表现层 UnitView 的实际 global basis
## 两者只要有一个在连续旋转，就能立刻定位是哪一层在转。
## 同时保存若干张视口截图，可直接看一眼。

const BATTLE := "res://scenes/battle/battle.tscn"
const LOG_EVERY := 10          ## 每 10 帧记一行（约 0.17 秒）
const CAPTURE_EVERY := 120     ## 每 120 帧存一张图
const TOTAL_FRAMES := 600

var _battle: Node = null
var _frame := 0
var _out_dir := ""

func _ready() -> void:
	var packed := load(BATTLE) as PackedScene
	if packed == null:
		print("[cap] 无法加载 %s" % BATTLE)
		get_tree().quit(1)
		return
	_battle = packed.instantiate()
	add_child(_battle)
	_out_dir = ProjectSettings.globalize_path("res://tools/temp/capture")
	DirAccess.make_dir_recursive_absolute(_out_dir)
	print("[cap] 输出目录 %s" % _out_dir)


func _process(_delta: float) -> void:
	_frame += 1

	if _frame % LOG_EVERY == 0:
		_log_units()

	if _frame % CAPTURE_EVERY == 0:
		_capture()

	if _frame >= TOTAL_FRAMES:
		print("[cap] 结束")
		get_tree().quit(0)


func _log_units() -> void:
	var parts := PackedStringArray()

	# 相机姿态：如果玩家没输入而它在变，就是“镜头自己在转”
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		var cb := cam.global_transform.basis
		var cz := cb.z.normalized()
		parts.append("CAM pos=(%.0f,%.0f,%.0f) z=(%.3f,%.3f,%.3f)" % [
			cam.global_position.x, cam.global_position.y, cam.global_position.z,
			cz.x, cz.y, cz.z])

	# 天空旋转：equirect 全景若被绕着转，会看到整个星空在转
	var world_env := _find_world_environment(get_tree().current_scene if get_tree() != null else null)
	if world_env != null and world_env.environment != null:
		var env := world_env.environment
		if env.sky != null:
			parts.append("SKY rot=%.4f" % env.sky_rotation)

	var views := _collect_views(_battle)
	if views.is_empty():
		parts.append("找不到 UnitView")
	for v in views:
		var unit: Unit = v.unit()
		if unit == null:
			continue
		var sim_fwd: Vector3 = unit.forward
		var render_fwd: Vector3 = v.render_forward()
		var basis_x: Vector3 = v.global_transform.basis.x.normalized()
		# 模型子节点的相对旋转：如果 GLB 自带动画，这里会变
		var model_basis_x := Vector3.ZERO
		for child in v.get_children():
			if child is Node3D:
				model_basis_x = (child as Node3D).transform.basis.x.normalized()
				break
		parts.append("#%d sim=(%.2f,%.2f,%.2f) ren=(%.2f,%.2f,%.2f) vX=(%.2f,%.2f,%.2f) mX=(%.2f,%.2f,%.2f)" % [
			unit.id,
			sim_fwd.x, sim_fwd.y, sim_fwd.z,
			render_fwd.x, render_fwd.y, render_fwd.z,
			basis_x.x, basis_x.y, basis_x.z,
			model_basis_x.x, model_basis_x.y, model_basis_x.z])
	print("[cap] f=%d  " % _frame + "  ||  ".join(parts))


func _find_world_environment(node: Node) -> WorldEnvironment:
	if node == null:
		return null
	if node is WorldEnvironment:
		return node as WorldEnvironment
	for child in node.get_children():
		var found := _find_world_environment(child)
		if found != null:
			return found
	return null


func _collect_views(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		if child is UnitView:
			out.append(child)
		out.append_array(_collect_views(child))
	return out


func _capture() -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return
	var path := "%s/frame_%04d.png" % [_out_dir, _frame]
	image.save_png(path)
	print("[cap] 截图 %s" % path)
