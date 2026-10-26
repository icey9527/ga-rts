extends Node3D

## 回归：per-unit 战斗行为（T-4.2）。
##
## 之前 15 个机型只有一种行为：一路压到开火距离。除了数值不同，打法完全一样。
## 本场景把**同一机型**分别装上四种行为打靶，证明走位真的不同：
##   close_in  压到能打的最小距离
##   standoff  保持中距离（明显比 close_in 远）
##   orbit     绕着目标飞（方位角持续累加）
##   strafe    打完侧向换位（方位变化比 close_in 多）
##
## 隔离手段：每种行为单独开一个会话，靶子 hp 拉满且**卸掉武器**，
## 这样只测走位，不会被反击打死。

const DT := 1.0 / 60.0
const TICKS := 1200          # 20 秒
const ATTACK_DEF := "fighter"
const TARGET_DEF := "ou05"
const START := Vector3(0.0, 0.0, 1500.0)

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_bhv] ==== 战斗行为原型 ====")

	var close_in := _run(&"close_in")
	var standoff := _run(&"standoff")
	var orbit := _run(&"orbit")
	var strafe := _run(&"strafe")

	_info("  close_in ：最终距离 %.0f m，方位累计 %.0f°，路程 %.0f m / 净位移 %.0f m" % [
		close_in["dist"], close_in["azimuth"], close_in["path"], close_in["net"]])
	_info("  standoff ：最终距离 %.0f m，方位累计 %.0f°" % [
		standoff["dist"], standoff["azimuth"]])
	_info("  orbit    ：最终距离 %.0f m，方位累计 %.0f°" % [
		orbit["dist"], orbit["azimuth"]])
	_info("  strafe   ：最终距离 %.0f m，方位累计 %.0f°" % [
		strafe["dist"], strafe["azimuth"]])

	# 1. close_in 真的压上去
	_expect(float(close_in["dist"]) < 800.0,
		"close_in 压到开火距离附近（%.0f m < 800）" % close_in["dist"])

	# 2. standoff 明显比 close_in 远 —— 这是行为的核心差异
	_expect(float(standoff["dist"]) > float(close_in["dist"]) + 100.0,
		"standoff 保持距离（%.0f m 比 close_in %.0f m 远 100 m 以上）" % [
			standoff["dist"], close_in["dist"]])

	# 3. orbit 在绕目标飞
	_expect(absf(float(orbit["azimuth"])) > 180.0,
		"orbit 绕着目标飞（方位累计 %.0f° > 180°）" % orbit["azimuth"])

	# 4. strafe 的方位变化比 close_in 多（换位导致机头/方位反复改变）
	_expect(absf(float(strafe["azimuth"])) > absf(float(close_in["azimuth"])),
		"strafe 方位变化多于 close_in（%.0f° vs %.0f°）" % [
			strafe["azimuth"], close_in["azimuth"]])

	# 5. 确定性：同一行为跑两次结果一致
	var again := _run(&"close_in")
	_expect(absf(float(again["dist"]) - float(close_in["dist"])) < 1.0,
		"同输入两次结果一致（%.2f vs %.2f m）" % [again["dist"], close_in["dist"]])

	print("[verify_bhv] ---- 结果 ----")
	print("[verify_bhv]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_bhv] PASS")
		get_tree().quit(0)
	else:
		print("[verify_bhv] FAIL")
		get_tree().quit(1)


## 跑一次：一个攻击者按指定行为打一个不还手的靶子，返回走位统计
func _run(kind: StringName) -> Dictionary:
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)

	var target := session.spawn_unit(TARGET_DEF, Vector3.ZERO, 1)
	var attacker := session.spawn_unit(ATTACK_DEF, START, 0)
	if target == null or attacker == null:
		session.shutdown()
		return {"dist": -1.0, "azimuth": 0.0, "path": 0.0, "net": 0.0}

	# 靶子：血拉满 + 卸掉武器（只测走位，不被反击打死）
	target.max_hp = 1.0e9
	target.hp = 1.0e9
	target.weapons = null
	attacker.behavior_kind = kind

	CommandBus.issue([attacker], BattleSession.CMD_ATTACK,
		{"target": target, "source": &"verify_bhv"})

	var prev_angle := _bearing(attacker.position)
	var azimuth := 0.0
	var prev_pos := attacker.position
	var path := 0.0
	for i in TICKS:
		session.tick(DT)
		var angle := _bearing(attacker.position)
		azimuth += _wrap_deg(rad_to_deg(angle - prev_angle))
		prev_angle = angle
		path += attacker.position.distance_to(prev_pos)
		prev_pos = attacker.position

	var result := {
		"dist": attacker.position.distance_to(target.position),
		"azimuth": azimuth,
		"path": path,
		"net": START.distance_to(attacker.position),
	}
	session.shutdown()
	return result


## 以原点靶子为心的方位角
func _bearing(pos: Vector3) -> float:
	return atan2(pos.z, pos.x)


func _wrap_deg(deg: float) -> float:
	var d := deg
	while d > 180.0:
		d -= 360.0
	while d < -180.0:
		d += 360.0
	return d


func _info(text: String) -> void:
	print("[verify_bhv] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_bhv]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_bhv]   FAIL  %s" % what)
