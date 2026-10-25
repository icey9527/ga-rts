extends RefCounted
class_name Projectile

## 弹体（纯数据，ADR-0013）。
##
## 关键点：弹体**不是一个点**。3D 尺度下一 tick 能飞几十米，
## 点碰撞会直接穿过舰体（详见 verify_projectile 的穿透用例）。
## 因此每 tick 保留「上一帧位置 → 当前位置」这条线段，由 ProjectileManager
## 做扫掠求交。position 的语义是「本 tick 结束时的位置」，prev_position 是起点。
##
## 本类不判定命中、不结算伤害、不碰渲染——只负责运动学。

## 生命期：超时自动消失，防止漏删的弹体永远留在场上
var id := 0
var owner_id := -1
var team := 0

var position := Vector3.ZERO
var prev_position := Vector3.ZERO
var velocity := Vector3.ZERO

var damage := 0.0
## 弹体自身半径（参与扫掠求交，小口径 0.5 m，重型 2 m）
var radius := 0.5
var lifetime_left := 4.0

var alive := true


func _init(p_id: int = 0) -> void:
	id = p_id


## 推进一步。prev_position 必须在这一步里写好，否则本 tick 的扫掠段是空的。
func integrate(dt: float) -> void:
	prev_position = position
	position += velocity * dt
	lifetime_left -= dt
	if lifetime_left <= 0.0:
		alive = false


## 本 tick 的扫掠起点
func sweep_start() -> Vector3:
	return prev_position


## 本 tick 的扫掠终点
func sweep_end() -> Vector3:
	return position


## 本 tick 移动的距离（诊断用，验证穿透场景时看这个数）
func travel_distance() -> float:
	return prev_position.distance_to(position)


## 弹体朝向（渲染用）
func direction() -> Vector3:
	if velocity.length_squared() < 1e-12:
		return Vector3.FORWARD
	return velocity.normalized()
