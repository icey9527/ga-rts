extends Node3D

## 诊断：船是不是在"绕着目标飞圈"。
##
## 判据：以目标为原点，看船的方位角是否**持续单方向累加**。
## 正常交战会在某个方向附近来回微调（方位角净变化小）；
## 绕圈则方位角一圈圈累加，走满 360° 又 360°。
##
## 同时记录最近距离与转弯半径的比值 —— 转弯半径 >> 交战距离 时必然绕圈。

const DT := 1.0 / 60.0
const SECONDS := 30

func _ready() -> void:
	await get_tree().process_frame
	print("[orbit] ==== 是否绕圈诊断 ====")

	for pair in [["ou05", "ou134"], ["ou05", "ou05"], ["ou134", "ou134"],
			["fighter", "heavy"], ["interceptor", "fighter"]]:
		_probe(pair[0], pair[1])

	get_tree().quit(0)


func _probe(attacker_id: String, target_id: String) -> void:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	# 敌人在原点静止（不受命令），攻击者从 1200 m 外压上来
	var target := session.spawn_unit(target_id, Vector3.ZERO, 1)
	var attacker := session.spawn_unit(attacker_id, Vector3(0.0, 0.0, 1200.0), 0)
	if attacker == null or target == null:
		print("[orbit] %s → %s 生成失败" % [attacker_id, target_id])
		session.shutdown()
		return

	CommandBus.issue([attacker], BattleSession.CMD_ATTACK,
		{"target": target, "source": &"orbit"})

	var turn_radius := attacker.max_speed / attacker.turn_rate_yaw
	var prev_angle := _bearing(attacker.position, target.position)
	var accumulated := 0.0
	var min_dist := INF
	var dist_sum := 0.0
	var samples := 0

	for tick in SECONDS * 60:
		session.tick(DT)
		var d := attacker.position.distance_to(target.position)
		min_dist = minf(min_dist, d)
		dist_sum += d
		samples += 1
		var a := _bearing(attacker.position, target.position)
		accumulated += _wrap(rad_to_deg(a - prev_angle))
		prev_angle = a

	var avg_dist := dist_sum / float(maxi(samples, 1))
	var laps := absf(accumulated) / 360.0
	print("[orbit] %s(r=%.0f 转弯半径%.0f) → %s：%d 秒内方位角累计 %+.0f° = %.2f 圈，最近 %.0f m，平均距离 %.0f m → %s" % [
		attacker_id, attacker.radius, turn_radius, target_id, SECONDS,
		accumulated, laps, min_dist, avg_dist,
		"**绕圈**" if laps > 0.7 else "正常逼近/缠斗"])
	session.shutdown()


## 以目标为原点，攻击者的方位角（弧度）
func _bearing(from_pos: Vector3, around: Vector3) -> float:
	var d := from_pos - around
	return atan2(d.z, d.x)


func _wrap(deg: float) -> float:
	var d := deg
	while d > 180.0:
		d -= 360.0
	while d < -180.0:
		d += 360.0
	return d
