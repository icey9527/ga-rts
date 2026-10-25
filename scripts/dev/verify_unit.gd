extends Node3D

## 单位与移动验证场景（开发期工具，不属于游戏主流程）。
##
## 无头可跑、自动判定、退出码说话：
##     F:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path F:\godot\ga-rts \
##         scenes/dev/verify_unit.tscn
##     通过 → exit 0    失败 → exit 1
##
## 覆盖 T-1.5 的 10 条验收点（+ 第 11 条附加：表现层只读）：
##   1. 直线飞行抵达：给定 2 点路径，N 个 tick 后到达目标，误差 < 5 m
##   2. 速度上限：全程 speed ≤ max_speed + 1e-3
##   3. 刹车不过冲：最终位置不越过目标点
##   4. 转向角速度受限：每 tick 机头转角 ≤ turn_rate × dt + 1e-4，且不横移
##   5. 俯仰钳制：机头俯仰角不超过 ±60°
##   6. 机头不对就减速：90° 反向机头 → 期望速度降到 25%
##   7. 累加器：多次写只生效一次；apply 后清零且幂等
##   8. 单次积分断言：同一 tick 两次 step 不重复积分（CAPTURE 捕获，不炸进程）
##   9. 高度分层：target_y = 0 时收敛到 0±1；被推到 -1000 后回拉到带内
##  10. 确定性：同输入跑两次，逐元素相同
##  11.（附加）表现层只读：UnitView 反复插值后 unit 字段一字未变
##
## 本场景**不建任何单位节点参与模拟**：Unit / UnitMovement / UnitFlight 全是 RefCounted + 纯数学，
## 根节点只是为了能被 `--path ... xxx.tscn` 拉起来（用例 11 会实例化一个 UnitView 验证只读性）。

## 模拟步长（与 Simulation.TICK_RATE = 60 一致）
const DT := 1.0 / 60.0
## 三层高度（ADR-0003）
const LAYER_LOW := -400.0
const LAYER_CRUISE := 0.0
const LAYER_HIGH := 400.0
## 被测单位的性能参数（护卫舰量级，docs/scale-and-units.md）
const MAX_SPEED := 180.0
const ACCELERATION := 60.0
const DECELERATION := 80.0
const TURN_RATE_YAW_DEG := 30.0
const TURN_RATE_PITCH_DEG := 20.0
const UNIT_RADIUS := 20.0
## 直线用例的目标距离（米）
const TARGET_DISTANCE := 2000.0
## 到站误差上限（米）—— 验收用例 1
const ARRIVAL_TOLERANCE := 5.0
## 浮点噪声容差（单 tick 转角判定）
const TURN_EPSILON := 1.0e-4
## 刹车不过冲的容差（米）：离散积分 + 驻留钳位的残差
const OVERSHOOT_TOLERANCE := 1.0e-3
## 高度收敛容差（米）—— 验收用例 9
const ALTITUDE_TOLERANCE := 1.0
## 高度用例的最大 tick 数（1800 tick = 30 s）
const ALTITUDE_TICKS := 1800
## 用例 8 读的源码（确认断言真的写在守卫分支里）
const MOVEMENT_SCRIPT := "res://scripts/battle/unit/unit_movement.gd"

@export var unit_scene: PackedScene

var _failures: Array[String] = []
var _checks := 0


func _ready() -> void:
	# 等一帧：与其他 dev 场景保持一致的启动节奏
	await get_tree().process_frame

	_case_1_straight_flight()
	_case_2_speed_cap()
	_case_3_no_overshoot()
	_case_4_turn_rate()
	_case_5_pitch_clamp()
	_case_6_alignment_brake()
	_case_7_accumulators()
	_case_8_single_integration()
	_case_9_altitude_layers()
	_case_10_determinism()
	_case_11_view_readonly()
	_print_curves()

	_report()


# ---------------------------------------------------------------- 用例 1：直线飞行抵达

func _case_1_straight_flight() -> void:
	_header("1. 直线飞行抵达 —— 2 点路径，误差 < %.1f m" % ARRIVAL_TOLERANCE)
	var result := _fly_straight()
	var unit: Unit = result["unit"]
	var target: Vector3 = result["target"]
	var error := unit.position.distance_to(target)
	_info("起点 %s → 目标 %s（距离 %.1f m）" % [
		_short(Vector3.ZERO), _short(target), TARGET_DISTANCE])
	_info("参数：max_speed=%.1f accel=%.1f decel=%.1f yaw=%.1f°/s pitch=%.1f°/s" % [
		MAX_SPEED, ACCELERATION, DECELERATION, TURN_RATE_YAW_DEG, TURN_RATE_PITCH_DEG])
	_info("%d tick（%.2f s）后：位置 %s，速度 %.4f m/s，到站标志 %s，结束调用 %d 次" % [
		int(result["ticks"]), float(result["ticks"]) * DT, _short(unit.position),
		unit.speed, str(unit.is_route_finished()), unit.route_finished_count])
	_info("到站误差 = %.6f m" % error)

	_expect(unit.is_route_finished(), "航线走完（finished = true）")
	_expect(error < ARRIVAL_TOLERANCE,
		"误差 %.6f m < %.1f m" % [error, ARRIVAL_TOLERANCE])
	_expect(unit.route_finished_count == 1,
		"on_route_finished() 恰好调用 1 次（实际 %d）" % unit.route_finished_count)
	_expect(unit.speed < 1.0e-2, "抵达后速度收敛到 0（实际 %.6f m/s）" % unit.speed)


# ---------------------------------------------------------------- 用例 2：速度上限

func _case_2_speed_cap() -> void:
	_header("2. 速度上限 —— 全程 speed ≤ max_speed + 1e-3")
	var result := _fly_straight()
	var peak: float = result["peak_speed"]
	_info("全程峰值速度 = %.6f m/s，上限 %.1f m/s（耗时 %d tick）" % [
		peak, MAX_SPEED, int(result["ticks"])])
	_expect(peak <= MAX_SPEED + 1.0e-3,
		"峰值 %.6f ≤ %.1f + 1e-3" % [peak, MAX_SPEED])
	_expect(peak > MAX_SPEED - 0.5, "确实跑到了巡航速度（峰值 %.3f，不是一直在加速）" % peak)


# ---------------------------------------------------------------- 用例 3：刹车不过冲

func _case_3_no_overshoot() -> void:
	_header("3. 刹车不过冲 —— 最终位置不越过目标点")
	var result := _fly_straight()
	var unit: Unit = result["unit"]
	var target: Vector3 = result["target"]
	var overshoot: float = result["worst_overshoot"]
	var final_overshoot := -unit.position.z - TARGET_DISTANCE
	_info("最坏逐 tick 过冲量 = %.9f m（正数 = 越过目标）" % overshoot)
	_info("最终位置 z = %.9f，目标 z = %.1f，过冲 = %.9f m（容差 %.3f）" % [
		unit.position.z, target.z, final_overshoot, OVERSHOOT_TOLERANCE])
	_info("最终剩余距离 = %.9f m（刹车曲线 + 到站驻留钳位的残差）" % unit.position.distance_to(target))
	_expect(overshoot <= OVERSHOOT_TOLERANCE,
		"逐 tick 最坏过冲 %.9f m ≤ %.3f m" % [overshoot, OVERSHOOT_TOLERANCE])
	_expect(final_overshoot <= OVERSHOOT_TOLERANCE,
		"最终没有越过目标点（过冲 %.9f m）" % final_overshoot)


# ---------------------------------------------------------------- 用例 4：转向角速度

func _case_4_turn_rate() -> void:
	_header("4. 转向角速度受限 —— 每 tick 机头转角 ≤ %.2f°/tick + 1e-4" % (TURN_RATE_YAW_DEG * DT))
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.speed = MAX_SPEED
	# 第一段 100 m 正前方（飞过去 → 到站 → 第二段在右侧 90°）
	unit.set_route(PackedVector3Array([
		Vector3(0.0, 0.0, -100.0),
		Vector3(2000.0, 0.0, -100.0),
	]))

	var yaw_rate_rad := deg_to_rad(TURN_RATE_YAW_DEG)
	var limit := yaw_rate_rad * DT + TURN_EPSILON
	var max_turn := 0.0
	var max_lateral := 0.0
	var first_turn_tick := -1
	var headings := PackedFloat64Array()
	# 横移判定容差：位移方向与机头方向都是 float32，四元数往返（unit.forward → accum_rotation
	# → 归一化）会留下 ~1e-5 rad 的方向噪声，乘以单个 tick 的位移（≈0.4 m）就是 1e-5 m 量级。
	# 1e-4 m = 0.1 mm，纯属舍入噪声；真正的横移会是米级。
	var lateral_limit := 1.0e-4

	for i in 900:
		var forward_before := unit.forward
		var position_before := unit.position
		_step(unit)
		var turned := forward_before.angle_to(unit.forward)
		max_turn = maxf(max_turn, turned)
		if turned > 1.0e-6 and first_turn_tick < 0:
			first_turn_tick = i
		# 位移必须沿机头：扣掉沿机头的分量后剩下的就是"横移"（高度辅助在本用例里为 0）
		var displacement := unit.position - position_before
		if displacement.length_squared() > 1.0e-12:
			var along := unit.forward * displacement.dot(unit.forward)
			max_lateral = maxf(max_lateral, (displacement - along).length())
		if headings.size() < 12 and turned > 1.0e-6:
			headings.append(unit.yaw_degrees())

	_info("限值 = %.6f rad/tick = %.4f°/tick；实测单 tick 最大转角 = %.6f rad = %.4f°（比值 %.4f）" % [
		limit, rad_to_deg(limit), max_turn, rad_to_deg(max_turn), max_turn / limit])
	_info("首次开始转向在 tick %d；之后机头 yaw 依次 = %s" % [
		first_turn_tick, _degrees_text(headings)])
	_info("900 tick 后：位置 %s，yaw = %.2f°（转了 %.1f°），速度 %.2f m/s" % [
		_short(unit.position), unit.yaw_degrees(), -unit.yaw_degrees(), unit.speed])
	_info("最大横移量（扣掉沿机头分量）= %.9f m（限值 %.6f m = float32 舍入噪声量级）" % [
		max_lateral, lateral_limit])

	_expect(max_turn <= limit, "单 tick 最大转角 %.6f ≤ %.6f" % [max_turn, limit])
	_expect(max_turn > yaw_rate_rad * DT * 0.9,
		"转向确实跑到了限幅附近（%.6f rad vs %.6f），不是没转" % [max_turn, yaw_rate_rad * DT])
	_expect(max_lateral <= lateral_limit,
		"没有横移（最大 %.9f m ≤ %.6f m）" % [max_lateral, lateral_limit])


# ---------------------------------------------------------------- 用例 5：俯仰钳制

func _case_5_pitch_clamp() -> void:
	_header("5. 俯仰钳制 —— 机头俯仰角不超过 ±%.0f°" % Unit.MAX_PITCH_DEG)
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.speed = 120.0
	# 目标抬得很高：理想俯仰角 = atan(800 / 200) ≈ 76°，必须被钳在 60°
	var target := Vector3(0.0, 800.0, -200.0)
	unit.set_route(PackedVector3Array([target]))
	var wanted_pitch := rad_to_deg(atan2(target.y, -target.z))
	var max_pitch := 0.0
	var max_abs_pitch := 0.0
	var max_pitch_step := 0.0
	var pitch_rate := deg_to_rad(TURN_RATE_PITCH_DEG) * DT + TURN_EPSILON
	var pitch_samples := PackedFloat64Array()
	for i in 900:
		var pitch_before := unit.pitch_degrees()
		_step(unit)
		max_pitch = maxf(max_pitch, unit.pitch_degrees())
		max_abs_pitch = maxf(max_abs_pitch, absf(unit.pitch_degrees()))
		max_pitch_step = maxf(max_pitch_step, absf(deg_to_rad(unit.pitch_degrees() - pitch_before)))
		if i < 8:
			pitch_samples.append(unit.pitch_degrees())

	_info("目标方向 %s → 理想俯仰 %.2f°，钳位上限 %.0f°" % [
		_short(target), wanted_pitch, Unit.MAX_PITCH_DEG])
	_info("前 8 tick 俯仰角 = %s（每 tick ≤ %.4f°）" % [
		_degrees_text(pitch_samples), TURN_RATE_PITCH_DEG * DT])
	_info("900 tick 内最大仰角 = %.6f°，最大 |俯仰| = %.6f°，单 tick 最大俯仰变化 = %.6f°" % [
		max_pitch, max_abs_pitch, rad_to_deg(max_pitch_step)])
	_info("最终：位置 %s，俯仰 %.2f°，速度 %.2f m/s（确实在爬升）" % [
		_short(unit.position), unit.pitch_degrees(), unit.speed])

	_expect(max_pitch_step <= pitch_rate,
		"单 tick 俯仰变化 %.6f° ≤ %.6f°（%0.1f°/s × dt + 1e-4）" % [
			rad_to_deg(max_pitch_step), rad_to_deg(pitch_rate), TURN_RATE_PITCH_DEG])
	_expect(max_abs_pitch <= Unit.MAX_PITCH_DEG + 1.0e-3,
		"最大 |俯仰| %.6f° ≤ %.0f° + 1e-3" % [max_abs_pitch, Unit.MAX_PITCH_DEG])
	_expect(max_pitch > Unit.MAX_PITCH_DEG - 1.0,
		"确实顶到了钳位（%.3f°，不是没爬）" % max_pitch)
	_expect(unit.position.y > 100.0, "高度真的上去了（y = %.1f m）" % unit.position.y)


# ---------------------------------------------------------------- 用例 6：机头不对就减速

func _case_6_alignment_brake() -> void:
	_header("6. 机头不对就减速 —— 90° 反向机头 → 期望速度降到 25%")
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -1000.0)]))
	var dist := unit.distance_to_waypoint()

	unit.forward = Vector3.FORWARD
	var aligned := UnitMovement.desired_speed(unit, dist)
	unit.forward = Vector3(1.0, 0.0, 0.0)  # 机头朝 +X，目标在 -Z → 90°
	var right_angle := UnitMovement.desired_speed(unit, dist)
	unit.forward = Vector3.BACK  # 完全背对
	var reversed := UnitMovement.desired_speed(unit, dist)
	var brake_curve := minf(MAX_SPEED, sqrt(2.0 * DECELERATION * dist))

	_info("距离 %.1f m → 刹车曲线 min(%.1f, √(2·%.1f·%.1f)) = %.6f m/s" % [
		dist, MAX_SPEED, DECELERATION, dist, brake_curve])
	_info("对齐（dot=+1）期望速度 = %.6f m/s（100%%）" % aligned)
	_info("90°（dot= 0）期望速度 = %.6f m/s（%.4f%%，下限因子 %.2f）" % [
		right_angle, right_angle / brake_curve * 100.0, UnitMovement.MIN_ALIGNMENT_FACTOR])
	_info("180°（dot=-1）期望速度 = %.6f m/s（%.4f%%）" % [
		reversed, reversed / brake_curve * 100.0])
	_info("对齐因子表（dist = %.0f m）：" % dist)
	for dot in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		var sample := _make_unit()
		sample.set_route(PackedVector3Array([Vector3(0.0, 0.0, -1000.0)]))
		# 构造一个与期望方向夹角为 acos(dot) 的机头（绕世界 +Y 转，确定性）
		var yaw := acos(clampf(dot, -1.0, 1.0))
		sample.forward = Vector3(-sin(yaw), 0.0, -cos(yaw))
		_info("  dot=%+.2f → 期望速度 %8.4f m/s（比值 %.4f）" % [
			dot, UnitMovement.desired_speed(sample, dist),
			UnitMovement.desired_speed(sample, dist) / brake_curve])

	_expect(is_equal_approx(aligned, brake_curve),
		"对齐时期望速度 = 刹车曲线（%.6f vs %.6f）" % [aligned, brake_curve])
	_expect(absf(right_angle - brake_curve * 0.25) < 1.0e-6,
		"90° 时期望速度 = 25%% 刹车曲线（%.6f vs %.6f）" % [right_angle, brake_curve * 0.25])
	_expect(absf(reversed - brake_curve * 0.25) < 1.0e-6,
		"180° 时期望速度同样钳在 25%%（%.6f）" % reversed)


# ---------------------------------------------------------------- 用例 7：累加器

func _case_7_accumulators() -> void:
	_header("7. 累加器 —— 多次写只生效一次；apply 后清零且幂等")
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.speed = 10.0

	# 同一 tick 内写三次位移、两次速度增量、一次旋转
	unit.accum_position += Vector3(0.0, 0.0, -2.0)
	unit.accum_position += Vector3(0.0, 0.0, -3.0)
	unit.accum_position += Vector3(0.0, 0.0, -5.0)
	unit.accum_speed += 1.0
	unit.accum_speed += 2.0
	var rotation := Quaternion(Vector3.UP, deg_to_rad(2.0))
	unit.accum_rotation = rotation
	_info("写入 accum_position=(0,0,-10)、accum_speed=+3、绕 +Y 2° 后（累计值）")
	_info("  accum_position=%s accum_speed=%+.3f accum_rotation 角度=%.4f°" % [
		_short(unit.accum_position), unit.accum_speed, rad_to_deg(unit.accum_rotation.get_angle())])

	unit.apply_accumulators()
	var expected_forward := (rotation * Vector3.FORWARD).normalized()
	_info("apply 之后：position=%s speed=%.4f forward=%s yaw=%.4f°" % [
		_short(unit.position), unit.speed, _short(unit.forward), unit.yaw_degrees()])
	_info("  accum_position=%s accum_speed=%+.3f accum_rotation=identity:%s" % [
		_short(unit.accum_position), unit.accum_speed,
		str(unit.accum_rotation.is_equal_approx(Quaternion.IDENTITY))])

	_expect(unit.position.is_equal_approx(Vector3(0.0, 0.0, -10.0)),
		"三次写合并成一次位移（position = (0, 0, -10)，实际 %s）" % _short(unit.position))
	_expect(is_equal_approx(unit.speed, 13.0), "速度增量合并为 +3（实际 %.4f）" % unit.speed)
	_expect(unit.forward.is_equal_approx(expected_forward),
		"机头按 accum_rotation 转了 2°（实际 yaw %.4f°）" % unit.yaw_degrees())
	_expect(unit.accum_position == Vector3.ZERO and unit.accum_speed == 0.0
			and unit.accum_rotation.is_equal_approx(Quaternion.IDENTITY),
		"apply 之后三个 accum_* 全部清零")
	_expect(not unit.movement_active(), "apply 之后积分守卫已释放")

	var position_after := unit.position
	var speed_after := unit.speed
	var forward_after := unit.forward
	unit.apply_accumulators()
	_info("再次 apply（幂等性检查）：position=%s speed=%.4f" % [_short(unit.position), unit.speed])
	_expect(unit.position == position_after and unit.speed == speed_after
			and unit.forward == forward_after,
		"第二次 apply 是空操作（accum 已清零，不会重复位移）")

	# 状态切换清残留：写到一半被 set_route 打断，残余增量必须丢掉（ADR-0012）
	unit.accum_position += Vector3(50.0, 0.0, 0.0)
	unit.accum_speed += 99.0
	unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -500.0)]))
	_info("写了一半增量后 set_route：accum_position=%s accum_speed=%+.3f" % [
		_short(unit.accum_position), unit.accum_speed])
	_expect(unit.accum_position == Vector3.ZERO and unit.accum_speed == 0.0,
		"set_route 清空累加器（状态切换不留残余速度）")

	# reset_accumulators 单独可用
	unit.accum_position = Vector3.ONE
	unit.accum_speed = 7.0
	unit.reset_accumulators()
	_expect(unit.accum_position == Vector3.ZERO and unit.accum_speed == 0.0,
		"reset_accumulators() 单独可用")


# ---------------------------------------------------------------- 用例 8：单次积分断言

func _case_8_single_integration() -> void:
	_header("8. 单次积分断言 —— 同一 tick 两次 step 不重复积分")
	_expect(UnitMovement.guard_mode == UnitMovement.GuardMode.ASSERT,
		"默认守护模式 = ASSERT（生产路径走 assert）")

	# 断言确实写在守卫分支里（用 verify 自己的源码结构化检查，不去真的触发 assert）
	var source := FileAccess.get_file_as_string(MOVEMENT_SCRIPT)
	var has_assert := source.contains("assert(false") and source.contains("_movement_active")
	_info("源码 %s：%d 字节，包含 assert(false) 与 _movement_active = %s" % [
		MOVEMENT_SCRIPT, source.length(), str(has_assert)])
	_expect(has_assert, "断言写在 _movement_active 守卫分支内")

	# 切 CAPTURE：第二次积分只记账、不炸进程（验证场景不能被 assert 打断）
	UnitMovement.guard_mode = UnitMovement.GuardMode.CAPTURE
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -1000.0)]))

	UnitMovement.step(unit, DT, LAYER_CRUISE)
	var accum_first := unit.accum_position
	var active_after_first := unit.movement_active()
	UnitMovement.step(unit, DT, LAYER_CRUISE)
	var accum_second := unit.accum_position
	_info("第 1 次 step：accum_position=%s，守卫=%s" % [
		_short(accum_first), str(active_after_first)])
	_info("第 2 次 step：accum_position=%s，double_step_count=%d" % [
		_short(accum_second), unit.double_step_count])
	_expect(active_after_first, "第一次 step 之后守卫置位")
	_expect(unit.double_step_count == 1, "第二次 step 被计为重复积分（count = %d）" % unit.double_step_count)
	_expect(accum_second == accum_first, "第二次 step 没有改动 accum_position（未重复积分）")

	unit.apply_accumulators()
	var moved := unit.position.length()
	_info("apply 之后 position=%s（位移 %.6f m，= speed×dt 的第一次积分结果）" % [
		_short(unit.position), moved])
	_expect(moved < 0.5, "只积了一次：位移 %.6f m < 0.5 m（两次会是 %.3f m）" % [
		moved, moved * 2.0])

	var after_apply := unit.position
	UnitMovement.step(unit, DT, LAYER_CRUISE)
	_expect(unit.double_step_count == 1,
		"新 tick 又允许积分一次（count 仍是 %d）" % unit.double_step_count)
	unit.apply_accumulators()
	_expect(unit.position != after_apply, "新 tick 的积分生效了")

	UnitMovement.guard_mode = UnitMovement.GuardMode.ASSERT


# ---------------------------------------------------------------- 用例 9：高度分层

func _case_9_altitude_layers() -> void:
	_header("9. 高度分层 —— 3 层 + ±%.0f m 带 + 回归" % UnitFlight.BAND)
	var unit := _make_unit()

	# (a) 层中心 / 偏好偏移 / 带内钳位
	unit.cruise_altitude = 0.0
	var centers := PackedFloat64Array()
	for layer in [LAYER_LOW, LAYER_CRUISE, LAYER_HIGH]:
		centers.append(UnitFlight.cruise_target_y(unit, layer))
	_info("cruise_altitude=0 时三层目标高度 = %.1f / %.1f / %.1f" % [
		centers[0], centers[1], centers[2]])
	unit.cruise_altitude = 100.0
	var offset_in_band := UnitFlight.cruise_target_y(unit, LAYER_HIGH)
	unit.cruise_altitude = 400.0
	var offset_clamped := UnitFlight.cruise_target_y(unit, LAYER_HIGH)
	_info("cruise_altitude=+100 在 L2 → 目标 %.1f；cruise_altitude=+400（出带）→ 钳到 %.1f（带上沿 %.1f）" % [
		offset_in_band, offset_clamped, UnitFlight.band_high(LAYER_HIGH)])
	_expect(is_equal_approx(centers[0], LAYER_LOW) and is_equal_approx(centers[1], LAYER_CRUISE)
			and is_equal_approx(centers[2], LAYER_HIGH),
		"三层目标高度 = -400 / 0 / +400")
	_expect(is_equal_approx(offset_in_band, LAYER_HIGH + 100.0), "带内偏移生效（%.1f）" % offset_in_band)
	_expect(is_equal_approx(offset_clamped, UnitFlight.band_high(LAYER_HIGH)),
		"带外偏移被钳到带上沿（%.1f）" % offset_clamped)

	# (b) target_y = 0 时收敛到 0±1（起点在带内 100 m）
	unit.cruise_altitude = 0.0
	unit.position = Vector3(0.0, 100.0, 0.0)
	unit.speed = 0.0
	unit.reset_accumulators()
	var converge_tick := -1
	for i in 900:
		UnitFlight.steer_altitude(unit, LAYER_CRUISE, DT)
		unit.apply_accumulators()
		if converge_tick < 0 and absf(unit.position.y) <= ALTITUDE_TOLERANCE:
			converge_tick = i
	_info("(b) 起点 y=100（带内）→ 收敛到 y=%.6f 用了 %d tick；y 分量只由高度通道产生" % [
		unit.position.y, converge_tick])
	_expect(converge_tick >= 0, "900 tick 内收敛到 0±%.0f（tick %d）" % [ALTITUDE_TOLERANCE, converge_tick])
	_expect(absf(unit.position.y) <= ALTITUDE_TOLERANCE,
		"最终 |y| = %.6f ≤ %.0f" % [absf(unit.position.y), ALTITUDE_TOLERANCE])

	# (c) 被推到 -1000（带外）→ 允许越出，但必须回归
	unit.position = Vector3(0.0, -1000.0, 0.0)
	unit.speed = 0.0
	unit.reset_accumulators()
	var first_tick_y := 0.0
	var outside_ticks := 0
	var band_return_tick := -1
	var peak_excess := 0.0
	for i in ALTITUDE_TICKS:
		UnitFlight.steer_altitude(unit, LAYER_CRUISE, DT)
		unit.apply_accumulators()
		if i == 0:
			first_tick_y = unit.position.y
		var excess := absf(unit.position.y - UnitFlight.cruise_target_y(unit, LAYER_CRUISE))
		peak_excess = maxf(peak_excess, excess)
		if excess > UnitFlight.BAND:
			outside_ticks += 1
		elif band_return_tick < 0:
			band_return_tick = i
	_info("(c) 从 y=-1000 起步：第 1 tick 后 y=%.3f（没有被瞬间钳位，允许越出）" % first_tick_y)
	_info("    带外停留 %d tick（%.2f s），第 %d tick（%.2f s）回到 ±%.0f 带内" % [
		outside_ticks, outside_ticks * DT, band_return_tick, band_return_tick * DT, UnitFlight.BAND])
	_info("    最大偏差 %.1f m，%d tick 后 y=%.6f m（回拉速度上限 %.1f m/s）" % [
		peak_excess, ALTITUDE_TICKS, unit.position.y, UnitFlight.MAX_RETURN_SPEED])
	_expect(first_tick_y < -900.0, "允许短暂越出：第 1 tick 仍在带外（y=%.3f）" % first_tick_y)
	_expect(peak_excess > UnitFlight.BAND, "确实经历过带外（最大偏差 %.1f m）" % peak_excess)
	_expect(band_return_tick >= 0, "回到了 ±%.0f m 带内（tick %d）" % [UnitFlight.BAND, band_return_tick])
	_expect(absf(unit.position.y) <= ALTITUDE_TOLERANCE,
		"最终 |y| = %.6f ≤ %.0f（回归层中心）" % [absf(unit.position.y), ALTITUDE_TOLERANCE])

	# (d) 走 step() 的完整链路：高度通道同样只积分一次
	var mover := _make_unit()
	mover.position = Vector3(0.0, -1000.0, 0.0)
	mover.speed = 0.0
	mover.set_route(PackedVector3Array([Vector3(0.0, 0.0, -1.0)]))
	for i in 900:
		_step(mover)
	_info("(d) 走 UnitMovement.step 全程：y=-1000 → %.6f，double_step_count=%d" % [
		mover.position.y, mover.double_step_count])
	_expect(absf(mover.position.y) <= ALTITUDE_TOLERANCE,
		"step() 内部的 height 通道同样收敛到层中心（|y| = %.6f）" % absf(mover.position.y))
	_expect(mover.double_step_count == 0, "全程没有重复积分（count = %d）" % mover.double_step_count)


# ---------------------------------------------------------------- 用例 10：确定性

func _case_10_determinism() -> void:
	_header("10. 确定性 —— 同输入跑两次，逐元素相同")
	var first := _make_scenario_unit(1)
	var second := _make_scenario_unit(1)
	var mismatches := 0
	var first_mismatch := ""
	var ticks := 0
	for i in 600:
		_step(first)
		_step(second)  # 完全相同的输入（含层高），只有这样才能比较
		ticks += 1
		if first.position != second.position or first.forward != second.forward \
				or first.speed != second.speed:
			mismatches += 1
			if first_mismatch.is_empty():
				first_mismatch = "tick %d: pos %s vs %s / fwd %s vs %s / v %.9f vs %.9f" % [
					i, _short(first.position), _short(second.position),
					_short(first.forward), _short(second.forward), first.speed, second.speed]
	_info("两次运行各 %d tick（含转弯 + 爬升 + 高度回拉）" % ticks)
	_info("最终：pos %s vs %s" % [_short(first.position), _short(second.position)])
	_info("      fwd %s vs %s，speed %.9f vs %.9f" % [
		_short(first.forward), _short(second.forward), first.speed, second.speed])
	_info("逐元素不一致的 tick 数 = %d%s" % [
		mismatches, "" if first_mismatch.is_empty() else "，首个：" + first_mismatch])
	_expect(mismatches == 0, "600 tick 逐元素完全一致（不一致 %d 个 tick）" % mismatches)

	# 第三组：只改一个输入（起点位置）就必须不同 —— 防止"两边都没动"式的假通过
	var third := _make_scenario_unit(2)
	third.position.x += 1.0
	for i in 600:
		_step(third)
	_info("对照组（起点 x +1 m）最终 x = %.6f vs %.6f（确实不同）" % [
		first.position.x, third.position.x])
	_expect(third.position != first.position, "改一个输入结果就不同（不是恒等输出）")


# ---------------------------------------------------------------- 用例 11：表现层只读

func _case_11_view_readonly() -> void:
	_header("11.（附加）表现层只读 —— UnitView 插值不回写模拟")
	if unit_scene == null:
		_expect(false, "scenes/dev/verify_unit.tscn 没有指定 unit_scene")
		return
	var view := unit_scene.instantiate() as UnitView
	if view == null:
		_expect(false, "unit_base.tscn 的根节点不是 UnitView")
		return
	add_child(view)
	view.set_process(false)  # 由本用例自己驱动，不受引擎帧率影响

	var unit := _make_unit()
	unit.position = Vector3(0.0, 0.0, -100.0)
	unit.forward = Vector3.FORWARD
	view.bind(unit)
	_info("绑定位置 %s，视图初始位置 %s（bind 首帧直接贴合）" % [
		_short(unit.position), _short(view.render_position())])

	# (a) 只读：模拟状态不动，反复插值后 unit 一个字段都不许变
	var frozen_position := unit.position
	var frozen_forward := unit.forward
	var frozen_speed := unit.speed
	var frozen_route := unit.route.size()
	for i in 240:
		view.sync_visual(DT)
	_info("240 次 sync_visual 之后：unit.position=%s forward=%s speed=%.6f" % [
		_short(unit.position), _short(unit.forward), unit.speed])
	_expect(unit.position == frozen_position and unit.forward == frozen_forward
			and unit.speed == frozen_speed and unit.route.size() == frozen_route,
		"UnitView 没有回写 unit 的 position / forward / speed / route")

	# (b) 跟随：模拟跑起来，视图必须滞后但收敛（不瞬移）
	unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -1500.0)]))
	for i in 120:
		_step(unit)
		view.sync_visual(DT)
	var moving_lag := view.render_position().distance_to(unit.position)
	var sharpness := maxf(view.follow_sharpness, 1.0e-3)
	# 一阶跟随追匀加速目标时的稳态滞后 = v/k − a/k²（不是单纯的 v/k）
	var theoretical_lag := unit.speed / sharpness - ACCELERATION / (sharpness * sharpness)
	_info("模拟跑 120 tick（速度 %.2f m/s，位置 %s）：视图滞后 %.3f m（理论 v/k − a/k² = %.3f m）" % [
		unit.speed, _short(unit.position), moving_lag, theoretical_lag])
	_expect(moving_lag > 0.5, "行跟随时有平滑滞后（%.3f m），不是硬贴" % moving_lag)
	_expect(absf(moving_lag - theoretical_lag) < 2.0,
		"滞后符合一阶跟随的理论值（%.3f vs %.3f，差 %.3f）" % [
			moving_lag, theoretical_lag, absf(moving_lag - theoretical_lag)])

	# 模拟瞬移 30 m（小于 snap_distance，不触发贴合）→ 视图必须逐帧追上，不能一步到位
	unit.position += Vector3(0.0, 0.0, -30.0)
	var lag_before := view.render_position().distance_to(unit.position)
	view.sync_visual(DT)
	var lag_one_frame := lag_before - view.render_position().distance_to(unit.position)
	for i in 240:
		view.sync_visual(DT)
	var lag_after := view.render_position().distance_to(unit.position)
	_info("瞬移 30 m 后：滞后 %.3f m → 单帧收敛 %.3f m → 240 帧后 %.6f m" % [
		lag_before, lag_one_frame, lag_after])
	_expect(lag_one_frame > 0.0 and lag_one_frame < lag_before,
		"单帧只收敛一部分（%.3f m），不是瞬移" % lag_one_frame)
	_expect(lag_after < 0.01, "视图最终追上（残余 %.6f m）" % lag_after)

	# (c) 传送：超过 snap_distance 直接贴合，不在战场上拖一条线
	unit.position += Vector3(9000.0, 0.0, 0.0)
	view.sync_visual(DT)
	_info("传送 9000 m 后同步一次：视图位置 %s（应立刻贴合）" % _short(view.render_position()))
	_expect(view.render_position().distance_to(unit.position) < 1.0e-6,
		"超过 snap_distance 时直接贴合（滞后 %.6f m）" % view.render_position().distance_to(unit.position))

	# (d) 模型路径只能来自注册表（硬规则 5）
	var registry := GameState.registry()
	var expected_path := ""
	if registry != null:
		expected_path = registry.asset(unit.def_id)
	var attached := view.apply_model_from_registry()
	_info("registry.asset(\"%s\") = %s" % [unit.def_id, expected_path])
	_info("apply_model_from_registry() → 已挂模型 = %s，view.model_path() = %s" % [
		str(attached), view.model_path()])
	_expect(not expected_path.is_empty(), "注册表能解析出 %s 的模型路径" % unit.def_id)
	_expect(view.model_path() == expected_path,
		"模型路径来自注册表（%s）" % expected_path)
	_expect(attached, "模型已挂到 Model 节点上")

	view.queue_free()


# ---------------------------------------------------------------- 曲线样例

func _print_curves() -> void:
	_header("实测曲线样例（加速 / 刹车 / 转向）")

	# 加速曲线
	var accel_unit := _make_unit()
	accel_unit.position = Vector3.ZERO
	accel_unit.forward = Vector3.FORWARD
	accel_unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -3000.0)]))
	_info("加速：max_speed=%.0f acceleration=%.0f deceleration=%.0f" % [
		MAX_SPEED, ACCELERATION, DECELERATION])
	var marks := [0, 1, 2, 5, 10, 60, 120, 180]
	for i in 181:
		if i > 0:
			_step(accel_unit)
		if marks.has(i):
			_info("  t=%5.2f s  speed=%8.3f m/s  dist=%9.2f m  accum_speed(上 tick 已清)=%.3f" % [
				float(i) * DT, accel_unit.speed, accel_unit.distance_to_waypoint(),
				accel_unit.accum_speed])

	# 刹车曲线（纯函数表）
	var brake_unit := _make_unit()
	brake_unit.set_route(PackedVector3Array([Vector3(0.0, 0.0, -3000.0)]))
	brake_unit.forward = Vector3.FORWARD
	_info("刹车曲线 desired_speed = min(max_speed, √(2·decel·dist)) × 1.0（机头对齐）：")
	for dist in [3000.0, 2000.0, 1000.0, 500.0, 202.5, 100.0, 50.0, 20.0, 5.0, 2.0, 0.5]:
		_info("  dist=%8.2f m → %8.4f m/s（理论停车距离 %.4f m）" % [
			dist, UnitMovement.desired_speed(brake_unit, dist),
			pow(UnitMovement.desired_speed(brake_unit, dist), 2.0) / (2.0 * DECELERATION)])

	# 转向曲线
	var turn_unit := _make_unit()
	turn_unit.position = Vector3.ZERO
	turn_unit.forward = Vector3.FORWARD
	turn_unit.speed = MAX_SPEED
	turn_unit.set_route(PackedVector3Array([
		Vector3(0.0, 0.0, -100.0),
		Vector3(2000.0, 0.0, -100.0),
	]))
	_info("转向：yaw 上限 %.1f°/s（%.4f°/tick），目标在右侧 90°" % [
		TURN_RATE_YAW_DEG, TURN_RATE_YAW_DEG * DT])
	var printed := 0
	var started := false
	for i in 400:
		var before := turn_unit.forward
		_step(turn_unit)
		var turned := before.angle_to(turn_unit.forward)
		if turned > 1.0e-9:
			started = true
		if started and printed < 10:
			_info("  tick %3d  yaw=%8.3f°  Δ=%7.4f°  speed=%7.3f  x=%8.2f  z=%9.2f" % [
				i, turn_unit.yaw_degrees(), rad_to_deg(turned), turn_unit.speed,
				turn_unit.position.x, turn_unit.position.z])
			printed += 1

	# 俯仰曲线
	var pitch_unit := _make_unit()
	pitch_unit.position = Vector3.ZERO
	pitch_unit.forward = Vector3.FORWARD
	pitch_unit.speed = 120.0
	pitch_unit.set_route(PackedVector3Array([Vector3(0.0, 800.0, -200.0)]))
	_info("俯仰：pitch 上限 %.1f°/s（%.4f°/tick），目标方向理想俯仰 75.96°，钳位 %.0f°" % [
		TURN_RATE_PITCH_DEG, TURN_RATE_PITCH_DEG * DT, Unit.MAX_PITCH_DEG])
	for i in 12:
		var pitch_before := pitch_unit.pitch_degrees()
		_step(pitch_unit)
		_info("  tick %2d  pitch=%7.4f°  Δ=%7.4f°  y=%8.3f m  speed=%7.3f" % [
			i, pitch_unit.pitch_degrees(), pitch_unit.pitch_degrees() - pitch_before,
			pitch_unit.position.y, pitch_unit.speed])


# ---------------------------------------------------------------- 场景构造


## 直线用例：从原点飞向 -Z 方向 2000 m 的 2 点路径。
func _fly_straight() -> Dictionary:
	var unit := _make_unit()
	unit.position = Vector3.ZERO
	unit.forward = Vector3.FORWARD
	unit.speed = 0.0
	var target := Vector3(0.0, 0.0, -TARGET_DISTANCE)
	unit.set_route(PackedVector3Array([unit.position, target]))

	var peak_speed := 0.0
	var worst_overshoot := 0.0
	var ticks := 0
	# 上限 3000 tick = 50 s：2000 m 巡航 180 m/s 理论约 700 tick
	for i in 3000:
		_step(unit)
		ticks += 1
		peak_speed = maxf(peak_speed, unit.speed)
		worst_overshoot = maxf(worst_overshoot, -unit.position.z - TARGET_DISTANCE)
		if unit.is_route_finished() and unit.speed < 1.0e-3:
			break
	return {
		"unit": unit,
		"target": target,
		"ticks": ticks,
		"peak_speed": peak_speed,
		"worst_overshoot": worst_overshoot,
	}


## 确定性用例的公共场景：转弯 + 爬升 + 高度回拉的组合航线。
func _make_scenario_unit(p_id: int) -> Unit:
	var unit := _make_unit()
	unit.id = p_id
	unit.position = Vector3(0.0, 0.0, 0.0)
	unit.forward = Vector3.FORWARD
	unit.speed = 40.0
	unit.set_route(PackedVector3Array([
		Vector3(0.0, 0.0, -500.0),
		Vector3(500.0, 0.0, -1000.0),
		Vector3(500.0, 300.0, -1500.0),
		Vector3(0.0, 120.0, -1800.0),
	]))
	return unit


func _make_unit() -> Unit:
	var unit := Unit.new(7, "ou134")
	unit.max_speed = MAX_SPEED
	unit.acceleration = ACCELERATION
	unit.deceleration = DECELERATION
	unit.turn_rate_yaw = deg_to_rad(TURN_RATE_YAW_DEG)
	unit.turn_rate_pitch = deg_to_rad(TURN_RATE_PITCH_DEG)
	unit.radius = UNIT_RADIUS
	return unit


## 一个模拟 tick：积分 + 统一应用（与 Simulation 的 3 → 4 步一致）
func _step(unit: Unit, dt := DT, layer := LAYER_CRUISE) -> void:
	UnitMovement.step(unit, dt, layer)
	unit.apply_accumulators()


# ---------------------------------------------------------------- 输出工具


func _short(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


func _degrees_text(values: PackedFloat64Array) -> String:
	var parts := PackedStringArray()
	for value in values:
		parts.append("%.3f°" % value)
	return " → ".join(parts) if not parts.is_empty() else "(无)"


func _header(title: String) -> void:
	print("[verify] ---- %s" % title)


func _info(text: String) -> void:
	print("[verify]   %s" % text)


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
