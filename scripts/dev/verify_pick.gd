extends Node3D

## 回归：点选按**船体范围**判定，不是固定像素点（T-?）。
##
## 用户的直接反馈：“2D 是点击船身，你这是一点一个点”。
## 原版 get_unit_at 的口径是 `半径 × 1.4`（另有 8 px 屏幕最小半径），
## 我们原来是固定 18 px —— 母舰和战斗机一样大，点大船根本点不中。
##
## 本场景用真实相机投影验证：
##   · 大船：偏移到它的船体范围内仍能选中（旧实现 18 px 会判不中）
##   · 小船：同样的偏移不该选中它（否则一点就选中半个战场）
##   · 小船：贴到 8 px 以内必须选中（屏幕最小命中半径兜底）
##   · 空白处：不选中任何东西

const RIG_SCENE := "res://scenes/camera/rts_camera.tscn"
const BIG_RADIUS := 300.0
const SMALL_RADIUS := 8.0

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_pick] ==== 按船体点选 ====")

	var packed := load(RIG_SCENE) as PackedScene
	if packed == null:
		_expect(false, "加载相机场景")
		_report()
		return
	var rig := packed.instantiate() as RtsCameraRig
	add_child(rig)
	await get_tree().process_frame
	rig.force_mode(RtsCameraRig.ViewMode.VIEW_3D)
	rig.focus_on(Vector3.ZERO, true)

	var proj := rig.view_projection()
	var per_px := proj.world_units_per_pixel()
	_info("  每个屏幕像素对应 %.3f m" % per_px)
	_expect(per_px > 0.0, "投影换算可用（%.3f m/px）" % per_px)

	var big := {"position": Vector3(0.0, 0.0, 0.0), "radius": BIG_RADIUS}
	var small := {"position": Vector3(1200.0, 0.0, 0.0), "radius": SMALL_RADIUS}
	var big_screen: Vector2 = proj.world_to_screen(big["position"])
	var small_screen: Vector2 = proj.world_to_screen(small["position"])

	# 期望的可点半径（与实现同口径，只用来挑探测点，不用来断言数值）
	var big_reach := maxf(BIG_RADIUS * 1.4 / per_px, 8.0)
	var small_reach := maxf(SMALL_RADIUS * 1.4 / per_px, 8.0)
	_info("  大船可点半径约 %.0f px、小船约 %.1f px" % [big_reach, small_reach])
	_expect(big_reach > 18.0,
		"大船的可点半径 %.0f px 远超旧的固定 18 px" % big_reach)

	# 1. 大船：点到船体范围内 → 选中
	var hit_big: Variant = proj.pick_point(big_screen + Vector2(big_reach * 0.8, 0.0), [big, small])
	_expect(hit_big == big, "点在大船船体内 → 选中大船（实际 %s）" % str(hit_big != null))

	# 2. 小船：同样比例的偏移 → 不该选中它
	var far_offset := maxf(small_reach * 3.0, 24.0)
	var hit_small_far: Variant = proj.pick_point(small_screen + Vector2(far_offset, 0.0), [big, small])
	_expect(hit_small_far != small,
		"离小船 %.0f px 处不应选中它" % far_offset)

	# 3. 小船：贴到 8 px 内 → 必须选中（最小命中半径）
	var hit_small_near: Variant = proj.pick_point(small_screen + Vector2(4.0, 0.0), [big, small])
	_expect(hit_small_near == small, "贴在小船 4 px 处 → 选中它")

	# 4. 空白处：两个都不选中
	var empty_at: Vector2 = small_screen + Vector2(0.0, -400.0)
	var hit_empty: Variant = proj.pick_point(empty_at, [big, small])
	_expect(hit_empty == null, "空白处不选中任何东西（实际 %s）" % str(hit_empty))

	# 5. 没有 radius 的候选用固定半径兜底（保持旧行为，验证场景的假单位靠它）
	var plain := {"position": Vector3(600.0, 0.0, 0.0)}
	var plain_screen: Vector2 = proj.world_to_screen(plain["position"])
	var hit_plain: Variant = proj.pick_point(plain_screen + Vector2(6.0, 0.0), [plain])
	_expect(hit_plain == plain, "无 radius 的候选仍按固定半径命中")

	_report()


func _report() -> void:
	print("[verify_pick] ---- 结果 ----")
	print("[verify_pick]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_pick] PASS")
		get_tree().quit(0)
	else:
		print("[verify_pick] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_pick] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_pick]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_pick]   FAIL  %s" % what)
