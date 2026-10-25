extends Node3D

## 双相机验证场景（开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --path F:\godot\ga-rts \
##         scenes/dev/verify_camera.tscn
##     通过 → exit 0    失败 → exit 1
##
## 覆盖的四件事（对应 T-1.2 的验收点）：
##   1. 3D 焦点轨道相机 pan / orbit / pitch / zoom 的观测量（位置 + 距离）
##   2. 护栏：距离 30 m~12 km 钳位、俯仰 -85°~-5° 钳位、相机不得低于 5 m
##   3. ViewProjection 往返：50 个随机点 world→screen→world，3D < 2.0、2D < 0.5
##   4. 模式切换不丢焦点，且两种模式的投影都不过期（ViewProjection 重绑正确）

## 往返测试采样点个数
const ROUND_TRIP_COUNT := 50
## 3D 模式允许的最大往返误差（单位：米）
const MAX_ERROR_3D := 2.0
## 2D 模式允许的最大往返误差（更严格：正交是线性映射）
const MAX_ERROR_2D := 0.5
## 判定"落点在屏幕中心"的容差（像素）
const SCREEN_CENTER_TOLERANCE_PX := 2.0
## 数值比较容差
const EPSILON := 0.01
## 平滑收敛等待的最大帧数
const SETTLE_FRAMES := 180


@onready var camera_rig: RtsCameraRig = $CameraRig

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	# 等一帧：子节点的 _ready 与相机装配需要先跑完
	await get_tree().process_frame

	await _test_3d_operations()
	await _test_guardrails()
	await _test_smoothing()
	_reset_3d_state()
	_header("4. ViewProjection 往返")
	_test_round_trip("3D", MAX_ERROR_3D)
	await _test_round_trip_at_max_distance()
	_reset_3d_state()
	_test_pick("3D", 6)
	await _test_mode_switch()
	_header("8. ViewProjection 往返 —— 2D 模式")
	_test_round_trip("2D", MAX_ERROR_2D)
	_test_pick("2D", 9)
	await _test_back_to_3d()

	_report()


# ---------------------------------------------------------------- 用例 1：操作观测量

func _test_3d_operations() -> void:
	_header("1. 3D 焦点轨道相机 —— 每次操作后的相机位置与距离")
	_reset_3d_state()
	var cam := camera_rig.camera_3d
	_dump("初始", cam)

	cam.pan(Vector2(1000.0, 0.0))
	_dump("pan(右 1000 m)", cam)
	_expect(is_equal_approx(cam.focus_position.x, 1000.0), "pan 只沿相机右方移动焦点 x=1000")

	cam.pan(Vector2(0.0, 500.0))
	_dump("pan(上 500 m)", cam)
	_expect(is_equal_approx(cam.focus_position.z, -500.0), "pan 向上 = 世界 -Z（屏幕上方）")

	cam.orbit(30.0)
	_dump("orbit(+30°)", cam)
	_expect(is_equal_approx(cam.yaw_degrees, 30.0), "orbit 后 yaw = 30°")

	cam.pitch_by(-10.0)
	_dump("pitch(-10°)", cam)
	_expect(is_equal_approx(cam.pitch_degrees, RtsCamera3D.DEFAULT_PITCH_DEG - 10.0), "pitch_by 生效")

	cam.zoom_steps(2.0)
	await _settle(cam, func() -> bool: return is_equal_approx(cam.distance, cam.target_distance()))
	_dump("zoom_steps(+2 格，等平滑收敛)", cam)
	_expect(absf(cam.distance - cam.target_distance()) < 0.5, "滚轮缩放平滑收敛到目标距离")

	cam.focus_on(Vector3(3000.0, 0.0, -2000.0), true)
	_dump("focus_on(instant)", cam)
	_expect(cam.focus_position.is_equal_approx(Vector3(3000.0, 0.0, -2000.0)), "focus_on(instant) 立刻到位")

	cam.focus_on(Vector3(-1500.0, 0.0, 800.0), false)
	_dump("focus_on(平滑，第 0 帧)", cam)
	await _settle(cam, func() -> bool: return cam.focus_position.distance_to(Vector3(-1500.0, 0.0, 800.0)) < 0.5)
	_dump("focus_on(平滑，收敛后)", cam)
	_expect(cam.focus_position.distance_to(Vector3(-1500.0, 0.0, 800.0)) < 0.5, "focus_on 平滑收敛到目标焦点")


# ---------------------------------------------------------------- 用例 2：护栏

func _test_guardrails() -> void:
	_header("2. 护栏：距离 / 俯仰 / 穿地")
	var cam := camera_rig.camera_3d
	_reset_3d_state()

	cam.zoom_to(1.0, true)
	_dump("zoom_to(1 m)", cam)
	_expect(is_equal_approx(cam.distance, RtsCamera3D.MIN_DISTANCE), "距离下限钳到 30 m")

	cam.zoom_to(999999.0, true)
	_dump("zoom_to(999999 m)", cam)
	_expect(is_equal_approx(cam.distance, RtsCamera3D.MAX_DISTANCE), "距离上限钳到 12 km")

	cam.set_pitch_degrees(-120.0)
	_dump("pitch(-120°)", cam)
	_expect(is_equal_approx(cam.pitch_degrees, RtsCamera3D.MIN_PITCH_DEG), "俯仰下限钳到 -85°（向下看为正）")

	cam.set_pitch_degrees(30.0)
	_dump("pitch(+30°)", cam)
	_expect(is_equal_approx(cam.pitch_degrees, RtsCamera3D.MAX_PITCH_DEG), "俯仰上限钳到 -5°")

	# 穿地护栏：把焦点压到 -1000 m、俯仰压到最陡、距离压到下限，
	# 相机的名义高度是 -1000 + 30*sin(85°) ≈ -970 m，必须被抬到 5 m 以上
	cam.snap_focus(Vector3(0.0, -1000.0, 0.0))
	cam.set_pitch_degrees(RtsCamera3D.MIN_PITCH_DEG)
	cam.zoom_to(RtsCamera3D.MIN_DISTANCE, true)
	_dump("焦点 -1000 m + pitch -85° + 距离 30 m", cam)
	var camera_y := cam.camera().global_position.y
	_expect(camera_y >= RtsCamera3D.MIN_CAMERA_HEIGHT - EPSILON,
		"相机不得穿地（y=%.3f ≥ %.1f）" % [camera_y, RtsCamera3D.MIN_CAMERA_HEIGHT])

	cam.snap_focus(Vector3(1.0e6, 0.0, -1.0e6))
	_dump("snap_focus(1e6, 0, -1e6)", cam)
	_expect(is_equal_approx(cam.focus_position.x, RtsCamera3D.FOCUS_LIMIT_XZ)
		and is_equal_approx(cam.focus_position.z, -RtsCamera3D.FOCUS_LIMIT_XZ),
		"焦点钳在战场范围 +20%%（±%.0f m）" % RtsCamera3D.FOCUS_LIMIT_XZ)


# ---------------------------------------------------------------- 用例 3：平滑

func _test_smoothing() -> void:
	_header("3. 平滑：焦点与距离都指数收敛，不瞬移")
	_reset_3d_state()
	var cam := camera_rig.camera_3d
	cam.focus_on(Vector3(4000.0, 0.0, 0.0), false)
	await get_tree().process_frame
	await get_tree().process_frame
	var midway := cam.focus_position.x
	_expect(midway > 0.0 and midway < 4000.0,
		"focus_on 是插值而非瞬移（第 3 帧 x=%.1f m）" % midway)
	await _settle(cam, func() -> bool: return cam.focus_position.distance_to(Vector3(4000.0, 0.0, 0.0)) < 0.5)
	_dump("收敛后", cam)


# ---------------------------------------------------------------- 用例 4：往返

func _test_round_trip(label: String, limit: float) -> void:
	_header("ViewProjection 往返（%s 模式，%d 个随机点）" % [label, ROUND_TRIP_COUNT])
	var projection := camera_rig.view_projection()
	var size := projection.viewport_size()
	var screen_rect := Rect2(Vector2.ZERO, size)
	var focus := camera_rig.focus_position()
	var radius := _visible_radius()
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260101

	print("[verify]   投影 = %s，参考平面 y = %.1f，视口 = %s，采样半径 = %.1f m" % [
		"正交" if projection.is_orthographic() else "透视",
		projection.reference_height(), str(size), radius])

	var max_error := 0.0
	var used := 0
	for i in ROUND_TRIP_COUNT:
		var world := Vector3(
			focus.x + rng.randf_range(-radius, radius),
			projection.reference_height(),
			focus.z + rng.randf_range(-radius, radius))
		var screen := projection.world_to_screen(world)
		if not screen_rect.has_point(screen):
			continue
		var back := projection.screen_to_world(screen)
		max_error = maxf(max_error, back.distance_to(world))
		used += 1

	print("[verify]   采样 %d/%d 点，最大往返误差 = %.6f m（上限 %.2f）" % [
		used, ROUND_TRIP_COUNT, max_error, limit])
	_expect(used == ROUND_TRIP_COUNT, "%s：%d 个采样点全部落在屏幕内" % [label, ROUND_TRIP_COUNT])
	_expect(max_error < limit, "%s：最大往返误差 %.6f m < %.2f m" % [label, max_error, limit])

	# 焦点应该正好落在屏幕中心 —— 这条同时证明两台相机的"看哪里"口径一致
	var center_error := projection.world_to_screen(focus).distance_to(size * 0.5)
	print("[verify]   焦点投影偏离屏幕中心 = %.3f px" % center_error)
	_expect(center_error < SCREEN_CENTER_TOLERANCE_PX,
		"%s：焦点在屏幕中心（偏差 %.3f px）" % [label, center_error])


func _test_round_trip_at_max_distance() -> void:
	_header("5. ViewProjection 往返 —— 12 km 最远档（透视精度最差的位置）")
	camera_rig.camera_3d.zoom_to(RtsCamera3D.MAX_DISTANCE, true)
	_dump("zoom_to(12 km)", camera_rig.camera_3d)
	_test_round_trip("3D @12km", MAX_ERROR_3D)


# ---------------------------------------------------------------- 用例 5：拾取

func _test_pick(label: String, index: int) -> void:
	_header("%d. 屏幕空间拾取（%s 模式）" % [index, label])
	var projection := camera_rig.view_projection()
	var focus := camera_rig.focus_position()
	var radius := _visible_radius() * 0.5
	var candidates: Array = []
	for i in 5:
		candidates.append(Vector3(
			focus.x + radius * (float(i) - 2.0) * 0.5,
			projection.reference_height(),
			focus.z + radius * (float(i) - 2.0) * 0.25))

	var target: Vector3 = candidates[2]
	var hit: Variant = projection.pick_point(projection.world_to_screen(target), candidates)
	print("[verify]   pick_point(候选 2 的屏幕位置) = %s（期望 %s）" % [str(hit), str(target)])
	_expect(hit != null and hit == target, "%s：pick_point 命中最近的候选" % label)

	var picked := projection.pick_rect(Rect2(Vector2.ZERO, projection.viewport_size()), candidates)
	print("[verify]   pick_rect(全屏) 取回 %d / %d" % [picked.size(), candidates.size()])
	_expect(picked.size() == candidates.size(), "%s：pick_rect 全屏取回全部候选" % label)

	var empty := projection.pick_rect(Rect2(0.0, 0.0, 1.0, 1.0), candidates)
	_expect(empty.is_empty(), "%s：pick_rect 角落矩形取不到任何候选" % label)

	var miss: Variant = projection.pick_point(Vector2(-1000.0, -1000.0), candidates)
	_expect(miss == null, "%s：远离所有候选时 pick_point 返回 null" % label)


# ---------------------------------------------------------------- 用例 6：模式切换

func _test_mode_switch() -> void:
	_header("7. 模式切换：焦点不变、投影重绑、current 交接")
	_reset_3d_state()
	var cam := camera_rig.camera_3d
	cam.zoom_to(800.0, true)
	cam.set_yaw_degrees(25.0)
	cam.focus_on(Vector3(1200.0, 0.0, -800.0), true)
	var focus_before := camera_rig.focus_position()
	var camera_3d := cam.camera()
	print("[verify]   切换前 focus = %s，3D 相机位置 = %s，距离 = %.1f m" % [
		str(focus_before), str(camera_3d.global_position), cam.distance])

	camera_rig.set_mode(RtsCameraRig.ViewMode.VIEW_2D)
	var projection := camera_rig.view_projection()
	var camera_2d := camera_rig.camera_2d.camera()
	print("[verify]   切到 2D：focus = %s，2D 相机位置 = %s，正交视野 = %.1f m" % [
		str(camera_rig.focus_position()), str(camera_2d.global_position), camera_2d.size])

	_expect(camera_rig.focus_position().distance_to(focus_before) < EPSILON, "切到 2D 后焦点位置不变")
	_expect(projection.is_orthographic(), "切到 2D 后投影为正交")
	_expect(projection.camera() == camera_2d, "投影重绑到 2D 相机")
	_expect(camera_2d.is_current() and not camera_3d.is_current(), "current 从 3D 交接给 2D")
	_expect(camera_rig.camera_2d.accept_input, "2D 相机接管输入")
	_expect(not camera_rig.camera_3d.accept_input, "3D 相机交出输入")

	# 2D：无旋转（ADR-0002），视线必须笔直朝下
	var down := -camera_2d.global_transform.basis.z
	print("[verify]   2D 相机视线方向 = %s" % str(down))
	_expect(down.is_equal_approx(Vector3.DOWN), "2D 相机笔直向下看（无旋转 / 无俯仰）")

	# 2D 的缩放范围要与 3D 对齐
	camera_rig.camera_2d.zoom_to(1.0, true)
	_expect(is_equal_approx(camera_rig.camera_2d.view_size, RtsCamera2D.MIN_SIZE), "2D 视野下限钳到 30 m")
	camera_rig.camera_2d.zoom_to(999999.0, true)
	_expect(is_equal_approx(camera_rig.camera_2d.view_size, RtsCamera2D.MAX_SIZE), "2D 视野上限钳到 12 km")
	camera_rig.camera_2d.zoom_to(800.0, true)


func _test_back_to_3d() -> void:
	_header("10. 切回 3D：焦点仍然不变")
	var focus_before := camera_rig.focus_position()
	camera_rig.set_mode(RtsCameraRig.ViewMode.VIEW_3D)
	var projection := camera_rig.view_projection()
	print("[verify]   切回 3D：focus = %s，投影 = %s，3D 相机 current = %s" % [
		str(camera_rig.focus_position()),
		"正交" if projection.is_orthographic() else "透视",
		str(camera_rig.camera_3d.camera().is_current())])
	_expect(camera_rig.focus_position().distance_to(focus_before) < EPSILON, "切回 3D 后焦点位置不变")
	_expect(not projection.is_orthographic(), "切回 3D 后投影为透视")
	_expect(camera_rig.camera_3d.camera().is_current(), "current 交还给 3D 相机")
	await get_tree().process_frame


# ---------------------------------------------------------------- 工具

## 复位到干净的默认机位（每个用例都从同一个起点出发，输出才好读）
func _reset_3d_state() -> void:
	if camera_rig.mode() != RtsCameraRig.ViewMode.VIEW_3D:
		camera_rig.set_mode(RtsCameraRig.ViewMode.VIEW_3D)
	var cam := camera_rig.camera_3d
	cam.snap_focus(Vector3.ZERO)
	cam.set_yaw_degrees(0.0)
	cam.set_pitch_degrees(RtsCamera3D.DEFAULT_PITCH_DEG)
	cam.zoom_to(RtsCamera3D.DEFAULT_DISTANCE, true)
	camera_rig.view_projection().set_reference_height(cam.focus_position.y)


## 一个采样点集合在屏幕上大概能铺多大范围（保证 50 个点都落在视口内）
func _visible_radius() -> float:
	var size := camera_rig.view_projection().viewport_size()
	var aspect := size.x / maxf(size.y, 1.0)
	if camera_rig.view_projection().is_orthographic():
		var half := camera_rig.camera_2d.view_size * 0.5
		return minf(half, half * aspect) * 0.5
	var cam := camera_rig.camera_3d
	var half_height := cam.distance * tan(deg_to_rad(RtsCamera3D.CAMERA_FOV_DEG) * 0.5)
	var along_plane := half_height / maxf(cos(deg_to_rad(cam.pitch_degrees)), 0.05)
	return minf(along_plane, along_plane * aspect) * 0.5


func _settle(cam: RtsCamera3D, done: Callable) -> void:
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
		if done.call():
			return
	await get_tree().process_frame


func _dump(label: String, cam: RtsCamera3D) -> void:
	print("[verify]   [%s] focus=%s 相机=%s 距离=%.1f m yaw=%.1f° pitch=%.1f°" % [
		label,
		_short(cam.focus_position),
		_short(cam.camera().global_position),
		cam.distance,
		cam.yaw_degrees,
		cam.pitch_degrees])


func _short(v: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [v.x, v.y, v.z]


func _header(title: String) -> void:
	print("[verify] ---- %s" % title)


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
