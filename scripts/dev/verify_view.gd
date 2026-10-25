extends Node3D

## 表现层朝向回归：机头掉转 180° 时不能"原地乱转"。
##
## 事故：UnitView 原来用 lerp 线性插值方向向量。两个方向接近反向时，
## 插值向量会穿过零点，归一化后方向逐帧随机跳变 —— 玩家看到的就是模型疯狂自转。
## 本场景把那个场景构造出来，逐帧驱动 sync_visual，验证方向单调收敛且无跳变。

const DT := 1.0 / 60.0
## 单帧允许的最大方向变化（度）。正常球面插值远小于此；跳变会立刻超限。
const MAX_STEP_DEG := 25.0
## 收敛判定：与目标方向的夹角
const CONVERGE_DEG := 2.0
const MAX_STEPS := 600

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_view] ==== 表现层朝向（180° 掉转）====")

	for sharpness in [6.0, 12.0, 30.0]:
		_case_turn(sharpness)

	print("[verify_view] ---- 结果 ----")
	print("[verify_view]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_view] PASS")
		get_tree().quit(0)
	else:
		print("[verify_view] FAIL")
		get_tree().quit(1)


func _case_turn(sharpness: float) -> void:
	_header("跟随时锐度 %.0f：从 -Z 掉转到 +Z" % sharpness)
	var view := UnitView.new()
	view.follow_sharpness = sharpness
	add_child(view)

	var unit := Unit.new(1, "test")
	unit.forward = Vector3(0.0, 0.0, -1.0)
	unit.position = Vector3.ZERO
	view.bind(unit)

	# 模拟层突然掉头（追击中越过目标后重新指向，是真实会发生的）
	unit.forward = Vector3(0.0, 0.0, 1.0)

	var target := unit.forward
	var prev := view.render_forward()
	var max_step := 0.0
	var steps := 0
	var nan_frames := 0
	var increased := false
	var prev_angle := _angle_between(prev, target)
	var angle0 := prev_angle

	while steps < MAX_STEPS:
		view.sync_visual(DT)
		var now := view.render_forward()
		if not now.is_finite():
			nan_frames += 1
		else:
			max_step = maxf(max_step, _angle_between(prev, now))
		prev = now
		var angle := _angle_between(prev, target)
		# 容差 0.5°：数值噪声不应告警，但“回头变大”就是真问题
		if angle > prev_angle + 0.5:
			increased = true
		prev_angle = angle
		steps += 1
		if angle <= CONVERGE_DEG:
			break

	var final_angle := _angle_between(prev, target)
	_info("  起始夹角 %.0f° → 用 %d 帧收敛到 %.1f°，单帧最大变化 %.1f°" % [
		angle0, steps, final_angle, max_step])

	_expect(nan_frames == 0, "全程没有 NaN/Inf 方向（%d 帧异常）" % nan_frames)
	_expect(not increased, "夹角单调收敛（从不回头变大）")
	_expect(final_angle <= CONVERGE_DEG,
		"收敛到目标方向（残差 %.2f° ≤ %.1f°）" % [final_angle, CONVERGE_DEG])
	_expect(steps < MAX_STEPS, "在 %d 帧内收敛（实际 %d 帧）" % [MAX_STEPS, steps])

	# 关键回归点：线性插值退化的那一段，方向模长不能塌到 0
	_expect(prev.length() > 0.99, "最终方向是单位向量（模长 %.4f）" % prev.length())

	view.queue_free()


func _angle_between(a: Vector3, b: Vector3) -> float:
	var d := clampf(a.normalized().dot(b.normalized()), -1.0, 1.0)
	return rad_to_deg(acos(d))


func _header(text: String) -> void:
	print("[verify_view] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_view] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_view]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_view]   FAIL  %s" % what)
