class_name SimpleAI
extends RefCounted

## 最小交战 AI（S4 之前的占位实现，**不是**正式 AI）。
##
## 存在的唯一理由：主场景能玩。S3 结束时场上两支舰队都原地待命 ——
## 没有 AI，玩家不给命令就永远打不起来（实测打开主场景一片安静）。
##
## 刻意做得很笨：
##   · 只做一件事 —— 给本方全部单位下一个「打掉那个最近的敌人」命令
##   · 目标死了才重新决策（不每 2 秒刷一次航线，否则单位会被反复重置航线、原地打转）
##   · 不评估优劣、不撤退、不集火取舍、不看高度层
##
## 走 CommandBus.issue() 而不是直接改单位字段（硬规则 1：单一命令入口）——
## 所以它和玩家用的是同一条命令路径，将来换成正式 AI 时上层不用动。

## 重新决策的间隔（秒）。只是"目标死了才发现"的轮询节拍，不是攻击频率
const REDECIDE_INTERVAL := 2.0

## 本 AI 控制的队伍号
var team := 1

var _cooldown := 0.0
## 当前锁定目标 id（-1 = 没有）
var _target_id := -1
## 累计下达的攻击命令数（诊断用）
var _orders := 0


func _init(p_team: int = 1) -> void:
	team = p_team


func target_id() -> int:
	return _target_id


func orders_issued() -> int:
	return _orders


## 每 tick 调用。dt 是模拟步长。
func tick(session: BattleSession, dt: float) -> void:
	if session == null or dt <= 0.0 or not is_finite(dt):
		return

	_cooldown -= dt
	if _cooldown > 0.0:
		return
	_cooldown = REDECIDE_INTERVAL

	var mine := _units_of(session, team)
	if mine.is_empty():
		return
	var enemies := _enemies_of(session, team)
	if enemies.is_empty():
		return

	# 现有目标还活着就不打扰 —— 频繁重下命令会把航线反复重置，单位原地打转
	if _target_id >= 0:
		var current := session.context().unit_by_id(_target_id)
		if current != null and current.alive:
			return

	var target := _nearest(enemies, _centroid(mine))
	if target == null:
		return
	_target_id = target.id
	_orders += 1
	CommandBus.issue(mine, BattleSession.CMD_ATTACK,
		{"target": target, "source": &"ai"})


# ---------------------------------------------------------------- 工具

func _units_of(session: BattleSession, want_team: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in session.units():
		if unit.alive and unit.team == want_team:
			out.append(unit)
	return out


func _enemies_of(session: BattleSession, my_team: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in session.units():
		if unit.alive and unit.team != my_team:
			out.append(unit)
	return out


func _nearest(units: Array[Unit], from: Vector3) -> Unit:
	var best: Unit = null
	var best_d := INF
	for unit in units:
		var d := from.distance_squared_to(unit.position)
		if d < best_d:
			best_d = d
			best = unit
	return best


func _centroid(units: Array[Unit]) -> Vector3:
	if units.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for unit in units:
		sum += unit.position
	return sum / float(units.size())
