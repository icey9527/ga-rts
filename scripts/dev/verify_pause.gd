extends Node3D

## 回归：暂停开关（Space，与旧版一致）。
##
## 之前完全没有暂停：InputMap 里没有对应动作、Simulation 也没有暂停状态。
## 本场景验证三件事：未暂停会推进、暂停期间**完全不推进**、恢复后继续推进。
##
## 注意用 physics_frame 等待：Simulation 活在 _physics_process 里。

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_pause] ==== 暂停开关 ====")

	# 1. 正常推进
	Simulation.set_paused(false)
	var t0 := Simulation.tick_index()
	await _wait_physics(12)
	var t1 := Simulation.tick_index()
	_info("  未暂停 12 物理帧：tick %d → %d" % [t0, t1])
	_expect(t1 > t0, "未暂停时模拟在推进（%d → %d）" % [t0, t1])

	# 2. 暂停
	var now_paused := Simulation.toggle_pause()
	_expect(now_paused, "toggle_pause() 切到已暂停")
	_expect(Simulation.paused, "Simulation.paused 为 true")
	var t2 := Simulation.tick_index()
	await _wait_physics(30)
	var t3 := Simulation.tick_index()
	_info("  暂停 30 物理帧：tick %d → %d" % [t2, t3])
	_expect(t3 == t2, "**暂停期间 tick 一个都不推进**（%d → %d）" % [t2, t3])

	# 3. 恢复
	var resumed_paused := Simulation.toggle_pause()
	_expect(not resumed_paused, "再切一次回到运行")
	var t4 := Simulation.tick_index()
	await _wait_physics(12)
	var t5 := Simulation.tick_index()
	_info("  恢复 12 物理帧：tick %d → %d" % [t4, t5])
	_expect(t5 > t4, "恢复后继续推进（%d → %d）" % [t4, t5])
	_expect(not Simulation.paused, "Simulation.paused 为 false")

	print("[verify_pause] ---- 结果 ----")
	print("[verify_pause]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_pause] PASS")
		get_tree().quit(0)
	else:
		print("[verify_pause] FAIL")
		get_tree().quit(1)


func _wait_physics(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _info(text: String) -> void:
	print("[verify_pause] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_pause]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_pause]   FAIL  %s" % what)
