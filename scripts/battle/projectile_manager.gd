extends RefCounted
class_name ProjectileManager

## 弹体管理与**扫掠**命中检测（ADR-0013）。
##
## 为什么必须扫掠：弹速 2000 m/s、固定 60 Hz → 每 tick 走 33.3 m。
## 一艘 10 m 厚的舰体在两点之间被完全跳过，点判定必漏。
## 所以每发弹用「上一帧位置 → 当前位置」的线段与目标球求交。
##
## 职责边界（ADR-0013「命中与伤害解耦」）：
##   本类**只**判定命中并给出命中点，**绝不**修改单位状态。
##   命中结果以记录数组返回，由调用方（BattleSession）交给目标侧结算。
##   这样伤害公式集中一处、可单测，将来做录像/回放不需要重算物理。

## 退化线段的阈值（平方）。低于此视为静止弹，只做点判定。
const SWEEP_EPSILON := 1e-8

var _projectiles: Array[Projectile] = []
var _next_id := 1

var _spawned := 0
var _expired := 0
var _hit_count := 0
var _sweep_tests := 0


## 发射一发弹。direction 会被归一化；返回新弹体（便于验证脚本拿引用）。
func spawn(
	origin: Vector3,
	direction: Vector3,
	speed: float,
	damage: float,
	team: int,
	owner_id: int,
	radius: float = 0.5,
	lifetime: float = 4.0
) -> Projectile:
	var dir := direction
	if dir.length_squared() < 1e-12:
		dir = Vector3.FORWARD
	else:
		dir = dir.normalized()

	var p := Projectile.new(_next_id)
	_next_id += 1
	p.owner_id = owner_id
	p.team = team
	p.position = origin
	p.prev_position = origin
	p.velocity = dir * speed
	p.damage = damage
	p.radius = radius
	p.lifetime_left = lifetime

	_projectiles.append(p)
	_spawned += 1
	return p


## 推进一步并做命中检测。
##
## units: 场上所有单位（需有 position / radius / team / alive 字段）
## 返回命中记录数组，每条：
##   { "projectile_id": int, "target_id": int, "point": Vector3, "damage": float }
##
## 本单位（owner_id）与同队单位不会被命中。同一发弹只记最近的一次命中。
func tick(units: Array, dt: float) -> Array:
	var hits: Array = []
	var survivors: Array[Projectile] = []

	for p in _projectiles:
		if not p.alive:
			_expired += 1
			continue

		p.integrate(dt)

		var best: Dictionary = {}
		var best_t := INF

		var a := p.sweep_start()
		var b := p.sweep_end()

		for u in units:
			if u == null:
				continue
			if not u.alive:
				continue
			if u.team == p.team:
				continue
			if u.id == p.owner_id:
				continue

			_sweep_tests += 1
			var r: float = u.radius + p.radius
			var res := swept_sphere_hit(a, b, u.position, r)
			if not res["hit"]:
				continue
			var t: float = res["t"]
			if t < best_t:
				best_t = t
				best = {
					"projectile_id": p.id,
					"target_id": u.id,
					"point": res["point"],
					"damage": p.damage,
					# 击杀归属：没这个就没法记「谁打死的」，死亡结算里只能记 -1
					"owner_id": p.owner_id,
					"team": p.team,
				}

		if not best.is_empty():
			# 命中即停：弹体就地结束，不再穿行
			hits.append(best)
			_hit_count += 1
			continue

		if p.alive:
			survivors.append(p)
		else:
			_expired += 1

	_projectiles = survivors
	return hits


## 扫掠球检测：线段 a→b 与以 center 为心、radius 为径的球求交。
##
## 返回 { "hit": bool, "t": float（0..1 的线段参数）, "point": Vector3 }
## 用二次方程求**首次进入**点，不是「最近点距离」近似——
## 后者在高速下会把「从球外掠过」误判成命中。
static func swept_sphere_hit(a: Vector3, b: Vector3, center: Vector3, radius: float) -> Dictionary:
	var d := b - a
	var m := a - center
	var len_sq := d.length_squared()
	var c := m.length_squared() - radius * radius

	# 起点已在球内：算命中，命中点取起点
	if c <= 0.0:
		return {"hit": true, "t": 0.0, "point": a}

	# 退化线段（本 tick 没动）：退化成点判定
	if len_sq < SWEEP_EPSILON:
		return {"hit": false}

	var bq := m.dot(d)
	var disc := bq * bq - len_sq * c
	if disc < 0.0:
		return {"hit": false}

	var t := (-bq - sqrt(disc)) / len_sq
	if t < 0.0 or t > 1.0:
		return {"hit": false}

	return {"hit": true, "t": t, "point": a + d * t}


## 清空（切关/测试重置用）
func clear() -> void:
	_projectiles.clear()
	_next_id = 1
	_spawned = 0
	_expired = 0
	_hit_count = 0
	_sweep_tests = 0


func active_count() -> int:
	return _projectiles.size()


func projectiles() -> Array[Projectile]:
	return _projectiles


func stats() -> Dictionary:
	return {
		"spawned": _spawned,
		"expired": _expired,
		"hits": _hit_count,
		"active": _projectiles.size(),
		"sweep_tests": _sweep_tests,
	}
