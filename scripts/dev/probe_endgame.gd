extends Node3D

## 诊断：**残局**（一方全灭后）幸存单位会不会一直打转。
##
## 用户现场：只播报两次受击 → 玩家两艘很快被打光 → AI 方失去目标。
## 假设：失去目标后 attack_move 仍为 true、旧航线终点是敌人最后的位置，
## 于是船绕着那个点或在原地持续改变朝向 —— 看起来就是"一直在转圈"。
##
## 测量：战斗结束后再跑 60 秒，逐秒记录每个幸存者的
##   位置、朝向、速度、是否有活动航线
## 并判据：
##   · 位置几乎不动（半径 < 30 m）但朝向累计变化 > 540°（1.5 圈）→ 原地打转
##   · 位置在移动但绕同一中心（方位角累计 > 360°）→ 绕圈飞行

const DT := 1.0 / 60.0
const SECONDS_AFTER := 60

func _ready() -> void:
	await get_tree().process_frame
	print("[endgame] ==== 残局打转诊断 ====")

	var reg := GameState.registry()
	var record := reg.map("skirmish")
	var map := MapDef.from_record("skirmish", record, reg)
	var session := BattleSession.new()
	session.setup(reg, CommandBus)
	session.set_layer_height(MapDef.layer_center(map.layer_default))
	for entry in map.obstacles:
		var ob := NavObstacle.new()
		ob.setup(entry.position, entry.radius, entry.top_y, entry.bottom_y)
		session.add_obstacle(ob)
	for entry in map.spawns:
		session.spawn_unit(entry.unit_id, entry.position, entry.team)

	var ai := SimpleAI.new(1)
	var tick := 0
	while tick < 7200 and not session.is_battle_over():
		ai.tick(session, DT)
		session.tick(DT)
		tick += 1

	print("[endgame] 战斗结束于 t=%d（%.1f 秒），winner=%d，剩余 %d 艘" % [
		tick, float(tick) * DT, session.winner(), session.unit_count()])

	# 残局：逐秒记录幸存者
	var survivors := session.units()
	if survivors.is_empty():
		print("[endgame] 没有幸存者")
		session.shutdown()
		get_tree().quit(0)
		return

	var prev_yaw := {}
	var prev_pos := {}
	var yaw_total := {}
	var path := {}
	for u in survivors:
		prev_yaw[u.id] = _yaw(u)
		prev_pos[u.id] = u.position
		yaw_total[u.id] = 0.0
		path[u.id] = 0.0

	print("[endgame] ---- 战斗结束后再观察 %d 秒 ----" % SECONDS_AFTER)
	for i in SECONDS_AFTER * 60:
		ai.tick(session, DT)
		session.tick(DT)
		for u in session.units():
			if not prev_yaw.has(u.id):
				prev_yaw[u.id] = _yaw(u)
				prev_pos[u.id] = u.position
				yaw_total[u.id] = 0.0
				path[u.id] = 0.0
			yaw_total[u.id] = float(yaw_total[u.id]) + absf(_wrap(_yaw(u) - float(prev_yaw[u.id])))
			prev_yaw[u.id] = _yaw(u)
			path[u.id] = float(path[u.id]) + (u.position as Vector3).distance_to(prev_pos[u.id])
			prev_pos[u.id] = u.position
		if (i + 1) % 600 == 0:
			var parts := PackedStringArray()
			for u in session.units():
				parts.append("#%d %s pos=(%.0f,%.0f) yaw=%.0f° 速度%.0f 航线=%s 目标=%d" % [
					u.id, u.def_id, u.position.x, u.position.z, _yaw(u), u.speed,
					str(u.has_active_waypoint()), u.target_id])
			print("[endgame]   +%ds  %s" % [(i + 1) / 60, "  |  ".join(parts)])

	print("[endgame] ---- 判定 ----")
	for u in session.units():
		var yaw_sum := float(yaw_total[u.id])
		var travelled := float(path[u.id])
		var laps := yaw_sum / 360.0
		var verdict := "正常"
		if laps > 1.5 and travelled < 30.0:
			verdict = "**原地打转**（位置几乎不动，朝向累计 %.1f 圈）" % laps
		elif laps > 1.5:
			verdict = "**绕圈飞行**（走了 %.0f m，朝向累计 %.1f 圈）" % [travelled, laps]
		print("[endgame] #%d %s：朝向累计 %.0f°（%.2f 圈），路程 %.0f m → %s" % [
			u.id, u.def_id, yaw_sum, laps, travelled, verdict])

	session.shutdown()
	get_tree().quit(0)


func _yaw(unit: Unit) -> float:
	var f := unit.forward
	return rad_to_deg(atan2(f.x, f.z))


func _wrap(deg: float) -> float:
	var d := deg
	while d > 180.0:
		d -= 360.0
	while d < -180.0:
		d += 360.0
	return d
