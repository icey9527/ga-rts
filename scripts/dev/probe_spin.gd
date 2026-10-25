extends Node3D

## 诊断二：检测「位置几乎不动、但机头在连续旋转」——这才是玩家看到的"原地转圈"。
##
## 判据：每秒累计的 yaw 变化量。正常飞行时 yaw 会变化但位置也在动；
## 若 yaw 累计 > 180°/秒 而位置位移 < 5 m/秒，就是在原地打转。
##
## 同时覆盖三种状态：无命令、攻击中、以及战斗结束后（无目标）。

const DT := 1.0 / 60.0
const TICKS := 1800

func _ready() -> void:
	await get_tree().process_frame
	print("[probe2] ==== 原地旋转诊断 ====")

	# 场景 A：真实 map + AI（玩家方全程不下命令）
	_run_real_map()

	# 场景 B：单艘船，无任何命令
	_run_idle_unit()

	get_tree().quit(0)


func _run_real_map() -> void:
	var reg := GameState.registry()
	var record := reg.map("skirmish")
	var map := MapDef.from_record("skirmish", record, reg)
	var session := BattleSession.new()
	session.setup(reg, CommandBus)
	session.set_layer_height(MapDef.layer_center(map.layer_default))
	for entry in map.spawns:
		session.spawn_unit(entry.unit_id, entry.position, entry.team)

	var ai := SimpleAI.new(1)
	var prev_yaw := {}
	var prev_pos := {}
	var yaw_total := {}
	var pos_total := {}
	for u in session.units():
		prev_yaw[u.id] = _yaw_of(u)
		prev_pos[u.id] = u.position
		yaw_total[u.id] = 0.0
		pos_total[u.id] = 0.0

	print("[probe2] -- A. 真实 map + AI --")
	for tick in TICKS:
		ai.tick(session, DT)
		session.tick(DT)
		for u in session.units():
			if not prev_yaw.has(u.id):
				prev_yaw[u.id] = _yaw_of(u)
				prev_pos[u.id] = u.position
				yaw_total[u.id] = 0.0
				pos_total[u.id] = 0.0
			var y := _yaw_of(u)
			var dy := absf(_wrap_deg(y - float(prev_yaw[u.id])))
			yaw_total[u.id] = float(yaw_total[u.id]) + dy
			prev_yaw[u.id] = y
			pos_total[u.id] = float(pos_total[u.id]) + (u.position as Vector3).distance_to(prev_pos[u.id])
			prev_pos[u.id] = u.position
		if (tick + 1) % 600 == 0:
			var parts := PackedStringArray()
			for u in session.units():
				parts.append("#%d %s 偏航%.0f°/位移%.0fm" % [
					u.id, u.def_id, float(yaw_total[u.id]), float(pos_total[u.id])])
			print("[probe2]   t=%d 存活=%d | %s" % [tick + 1, session.unit_count(), "  ".join(parts)])

	print("[probe2]   最终逐单位：")
	for u in session.units():
		var yaw_sum := float(yaw_total[u.id])
		var pos_sum := float(pos_total[u.id])
		var spinning := yaw_sum > 180.0 * (TICKS * DT) * 0.5 and pos_sum < 5.0 * (TICKS * DT)
		print("[probe2]     #%d %s team=%d 总偏航 %.0f° 总位移 %.0f m → %s" % [
			u.id, u.def_id, u.team, yaw_sum, pos_sum,
			"**原地打转**" if spinning else "正常"])
	session.shutdown()


func _run_idle_unit() -> void:
	print("[probe2] -- B. 单艘船无命令 --")
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var u := session.spawn_unit("ou05", Vector3.ZERO, 0)
	var y0 := _yaw_of(u)
	var p0 := u.position
	for tick in 600:
		session.tick(DT)
	var yaw_delta := absf(_wrap_deg(_yaw_of(u) - y0))
	var moved := u.position.distance_to(p0)
	print("[probe2]   ou05 无命令 10 秒：偏航变化 %.1f°，位移 %.2f m，状态=%s" % [
		yaw_delta, moved, UnitStates.state_name(u.state)])
	session.shutdown()


## 取机头的水平偏航角（度）
func _yaw_of(unit: Unit) -> float:
	var f := unit.forward
	return rad_to_deg(atan2(f.x, f.z))


## 角度归一化到 -180..180
func _wrap_deg(deg: float) -> float:
	var d := deg
	while d > 180.0:
		d -= 360.0
	while d < -180.0:
		d += 360.0
	return d
