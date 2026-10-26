extends Node3D

## 回归：相机锁定跟随（旧版 `camera:set_follow` 的等价能力）。
##
## 之前只有一次性聚焦（`focus_on`）：点一下镜头跳一下，船开走了镜头不跟。
## 本场景验证真正的时间行为：焦点逐帧追上目标、目标移动时继续追、
## 目标阵亡/丢失时自动解除、手动清空后停下。

const RIG_SCENE := "res://scenes/camera/rts_camera.tscn"

var _checks := 0
var _fails := 0
var _rig: RtsCameraRig = null


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_follow] ==== 相机锁定跟随 ====")

	var packed := load(RIG_SCENE) as PackedScene
	if packed == null:
		_expect(false, "加载相机装配场景")
		_report()
		return
	_rig = packed.instantiate() as RtsCameraRig
	add_child(_rig)
	await get_tree().process_frame

	var unit := Unit.new(1, "test")
	unit.alive = true
	unit.position = Vector3(1000.0, 0.0, 0.0)

	_rig.force_mode(RtsCameraRig.ViewMode.VIEW_3D)
	_rig.focus_on(Vector3.ZERO, true)
	_rig.clear_follow_target()
	_expect(_rig.follow_target() == null, "初始没有跟随目标")

	# 1. 锁定后焦点向目标收敛
	_rig.set_follow_target(unit)
	_expect(_rig.follow_target() == unit, "跟随目标已锁定")
	var d0 := _rig.focus_position().distance_to(unit.position)
	for i in 30:
		_rig._process(1.0 / 60.0)
	var d1 := _rig.focus_position().distance_to(unit.position)
	_info("  30 帧后：距目标 %.1f m → %.1f m" % [d0, d1])
	_expect(d1 < d0 * 0.5, "焦点明显朝目标收敛（%.1f → %.1f）" % [d0, d1])

	# 2. 目标移动 → 镜头继续追
	unit.position = Vector3(1000.0, 0.0, 2000.0)
	var before := _rig.focus_position()
	for i in 60:
		_rig._process(1.0 / 60.0)
	var after := _rig.focus_position()
	_info("  目标跳到 z=2000 后：焦点 z %.1f → %.1f" % [before.z, after.z])
	_expect(after.z > before.z + 100.0, "目标移动时镜头跟着走（z %.1f → %.1f）" % [
		before.z, after.z])

	# 3. 目标阵亡 → 自动解除跟随（否则镜头会赖在尸体上）
	unit.alive = false
	_rig._process(1.0 / 60.0)
	_expect(_rig.follow_target() == null, "目标阵亡后自动解除跟随")
	var frozen := _rig.focus_position()
	unit.position = Vector3(-5000.0, 0.0, -5000.0)
	for i in 20:
		_rig._process(1.0 / 60.0)
	_expect(_rig.focus_position().distance_to(frozen) < 1.0,
		"解除后镜头不再动（位移 %.3f m）" % _rig.focus_position().distance_to(frozen))

	# 4. 手动清空
	var unit2 := Unit.new(2, "test")
	unit2.alive = true
	unit2.position = Vector3(0.0, 0.0, 800.0)
	_rig.set_follow_target(unit2)
	_expect(_rig.follow_target() == unit2, "重新锁定第二个目标")
	_rig.clear_follow_target()
	_expect(_rig.follow_target() == null, "手动清空生效")

	_report()


func _report() -> void:
	print("[verify_follow] ---- 结果 ----")
	print("[verify_follow]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_follow] PASS")
		get_tree().quit(0)
	else:
		print("[verify_follow] FAIL")
		get_tree().quit(1)


func _info(text: String) -> void:
	print("[verify_follow] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_follow]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_follow]   FAIL  %s" % what)
