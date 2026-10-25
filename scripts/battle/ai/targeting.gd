class_name Targeting
extends RefCounted

## 编队级集中选靶（ADR-0012 机制 #1，本卡的核心）。
##
## 原版 Project Sylpheed 的做法：**编队共享目标 Handle，个体不索敌**。
## 抄过来的三条要点，一条都不能省：
##   1. **扫描 1 秒节流**：不是每帧遍历敌人。60 个 tick 才扫一次，
##      100v100 时每帧的选靶开销因此与帧率无关（ADR-0012 机制 #6 的时间预算制同理）。
##   2. **按「预计接近时间」排序，不是裸距离**：一架 900 m 外朝你冲过来的截击机
##      比 600 m 外正在逃的靶船威胁大得多。裸距离排序会让全队去打最远的逃兵。
##   3. **被咬尾时后方目标优先**：本队有人 recently_damaged 时，反手先打从背后咬的。
##
## 只写 3 个地方：
##   squad.target_id / squad.target_switches   —— 编队级共享目标（权威值）
##   unit.target_id                            —— 成员的只读镜像（状态机读它，不必摸 squad）
##   本类自己的诊断计数
## **不写** position / forward / speed / accum_* / state —— 那是状态机与移动层的活。
##
## 为什么个体镜像 target_id 而不是让状态机自己去 squad 里查：
##   UnitStates.step(unit, ctx, dt) 的签名里没有 squad（规格如此），而且"这个单位在打谁"
##   是状态机最常读的字段。集中写、分散读，比让每个个体每 tick 走一遍 squad_of() 便宜。

## 扫描间隔（秒）。ADR-0012 写死 1 秒
const SCAN_INTERVAL := 1.0

## 浮点累积容差：60 × (1/60) 在 float64 下可能凑不满 1.0（差一个 ulp），
## 不补这个容差，节流会晚整整一帧，验证用例的"120 tick 扫 2 次"就会偶发变成 1 次。
const TIME_EPSILON := 1.0e-9

## 接近时间公式里的速度下限（m/s）：目标在逃 / 相对速度 <= 0 时用它兜底，
## 得到"接近时间 ≈ 无穷"（dist / 1e-6 ≈ 1e9 秒），排序天然沉底，且不会除零。
const CLOSING_EPSILON := 1.0e-6

## 索敌范围 = 射程 × 该倍数。
## 为什么要比射程大：射程内的敌人是"现在能打"，射程外一点的是"马上能打"，
## 只扫射程内就永远没有"接近时间"这个维度可排 —— 全员同一时刻可打，排序退化成裸距离。
## 1.5 是占位值：TBL 里已经有 radar（2600~3600 m），S2 雷达进 Unit 后改用 radar。
const ACQUIRE_FACTOR := 1.5

## 排序比较的浮点容差（接近时间 / 距离）。绝对相等的判定用
const COMPARE_EPSILON := 1.0e-9

# ---------------------------------------------------------------- 诊断计数

## 实际执行的扫描次数（节流后的）
var _scan_count := 0
## 累计参与排序的候选数（每次扫描每编队每敌人算一个）
var _candidate_total := 0
## 目标切换次数（-1 → 有目标不算切换，算"首次捕获"；有目标 → 换人 / 丢失才算）
var _switch_count := 0
## 首次捕获次数（从无目标到有目标）
var _acquire_count := 0
## 扫过但没有拿到任何候选的编队次（诊断"为什么全队不动"）
var _empty_squads := 0

## 距离上次扫描累积的真实时间（秒）
var _elapsed := 0.0


# ---------------------------------------------------------------- 主入口


## 每 tick 调一次。节流没到点就只做一件廉价的事：**校验旧目标是否还活着**。
##
## 为什么要每 tick 校验（而不是等下一次扫描）：目标可能在两次扫描之间被打死，
## 这一秒内所有人都会对着尸体开火。校验是 O(编队数)，可以忽略不计。
func update(ctx: BattleContext, dt: float) -> void:
	if ctx == null:
		push_error("[Targeting] ctx 为 null，跳过本次索敌")
		return
	if dt <= 0.0 or not is_finite(dt):
		push_error("[Targeting] dt 非法（%f），跳过本次索敌" % dt)
		return

	_drop_stale_targets(ctx)

	_elapsed += dt
	if _elapsed + TIME_EPSILON < SCAN_INTERVAL:
		return
	# 一次 update 最多扫描一次：dt 被拉大（掉帧补跑）时宁可少扫，也不在一个 tick 里连扫多次
	_elapsed = maxf(_elapsed - SCAN_INTERVAL, 0.0)
	_scan_count += 1

	for squad in ctx.squads():
		_scan_squad(squad, ctx)


# ---------------------------------------------------------------- 单个编队


## 给一个编队选一个共享目标。
## 单位向"谁"开火是**编队级**决策：同一编队全员打同一个目标（集中火力），
## 个体不再各自挑 —— 这是"集中选靶"的名字来源。
func _scan_squad(squad: Squad, ctx: BattleContext) -> void:
	var members := squad.alive_units()
	if members.is_empty():
		_set_target(squad, null, members)
		return

	var enemies := ctx.enemies_of(squad.team)
	if enemies.is_empty():
		_empty_squads += 1
		_set_target(squad, null, members)
		return

	# 「被咬尾」是按**编队**判定的：只要有一个成员刚挨打，全队优先反手
	var ambushed := false
	for member in members:
		if member.recently_damaged:
			ambushed = true
			break

	var best: Unit = null
	var best_id := 0
	var best_dist := 0.0
	var best_time := 0.0
	var best_behind := false

	for enemy in enemies:
		var probe := _evaluate(enemy, members)
		if probe.is_empty():
			continue  # 超出索敌范围
		_candidate_total += 1
		if best == null or _prefer(probe, best_id, best_dist, best_time, best_behind, ambushed):
			best = enemy
			best_id = enemy.id
			best_dist = float(probe["dist"])
			best_time = float(probe["time"])
			best_behind = bool(probe["behind"])

	if best == null:
		_empty_squads += 1
	_set_target(squad, best, members)


## 候选是否优于当前最优。
##
## 排序键（依次比较）：
##   1. 被咬尾时：后方目标优先（behind 为真）
##   2. 预计接近时间小者优先 —— **不是**距离
##   3. 距离更近者优先（接近时间相同的兜底）
##   4. id 更小者优先（最后一道兜底，只为了让"完全相同"的候选也有确定顺序）
static func _prefer(candidate: Dictionary, best_id: int, best_dist: float,
		best_time: float, best_behind: bool, ambushed: bool) -> bool:
	var behind := bool(candidate["behind"])
	if ambushed and behind != best_behind:
		return behind

	var time := float(candidate["time"])
	if time < best_time - COMPARE_EPSILON:
		return true
	if time > best_time + COMPARE_EPSILON:
		return false

	var dist := float(candidate["dist"])
	if dist < best_dist - COMPARE_EPSILON:
		return true
	if dist > best_dist + COMPARE_EPSILON:
		return false

	return int(candidate["id"]) < best_id


## 评估一个敌人对编队的威胁。返回空字典 = 超出索敌范围（不算候选）。
##
## 用**离它最近的成员**作为参考个体：威胁是"谁最先接火"，而不是"编队中心离它多远"。
## 编队散开时中心可能在很远的地方，用中心会把近在眼前的敌人判成不构成威胁。
##
## 预计接近时间 t = dist / max(相对接近速度, CLOSING_EPSILON)
##   相对接近速度 = (我的速度矢量 − 它的速度矢量) · 指向它的单位向量
##   > 0 = 双向奔赴；= 0 = 并排飞（t 巨大）；< 0 = 它在跑（t 巨大）
static func _evaluate(enemy: Unit, members: Array[Unit]) -> Dictionary:
	var reference: Unit = null
	var best_dist := INF
	for member in members:
		if member == enemy:
			continue
		var d := member.position.distance_to(enemy.position)
		if d < best_dist:
			best_dist = d
			reference = member
	if reference == null:
		return {}

	var acquire_range := reference.weapon_range * ACQUIRE_FACTOR
	if best_dist > acquire_range:
		return {}

	var offset := enemy.position - reference.position
	var direction := reference.forward
	if offset.length_squared() > 1.0e-12:
		direction = offset.normalized()

	# 相对接近速度沿"指向敌人"方向的分量
	var closing := closing_speed(reference, enemy)

	return {
		"id": enemy.id,
		"best_id": reference.id,
		"dist": best_dist,
		"time": approach_time(reference, enemy),
		"closing": closing,
		# 后方 / 咬尾：敌人在参考个体的后半空间（机头方向点积 < 0）
		"behind": direction.dot(reference.forward) < 0.0,
		"in_range": best_dist <= reference.weapon_range,
	}


# ---------------------------------------------------------------- 可单测的纯函数


## 沿「from → to」方向的相对接近速度（m/s）。
##   > 0 双向奔赴   = 0 并排飞   < 0 对方在跑
## 用速度**矢量**差而不是标量速度差：两艘同为 300 m/s 但并排飞的船相对接近速度是 0。
static func closing_speed(from_unit: Unit, to_unit: Unit) -> float:
	if from_unit == null or to_unit == null:
		return 0.0
	var offset := to_unit.position - from_unit.position
	var direction := from_unit.forward
	if offset.length_squared() > 1.0e-12:
		direction = offset.normalized()
	return (from_unit.velocity() - to_unit.velocity()).dot(direction)


## 预计接近时间（秒）= 距离 / max(相对接近速度, CLOSING_EPSILON)。
## 这是本卡选靶的**主排序键**（ADR-0012：按接近时间排序，不是裸距离）。
## 对方在逃时接近速度 <= 0 → 时间极大（≈ 1e9 s），排序天然沉底且不会除零。
static func approach_time(from_unit: Unit, to_unit: Unit) -> float:
	if from_unit == null or to_unit == null:
		return INF
	var dist := from_unit.position.distance_to(to_unit.position)
	return dist / maxf(closing_speed(from_unit, to_unit), CLOSING_EPSILON)


## 写编队级共享目标 + 成员的只读镜像（唯一写 unit.target_id 的地方）
func _set_target(squad: Squad, target: Unit, members: Array[Unit]) -> void:
	var new_id := Squad.NO_TARGET if target == null else target.id
	var previous := squad.target_id
	if new_id != previous:
		if new_id == Squad.NO_TARGET:
			_switch_count += 1  # 丢失目标也算一次切换
		elif previous == Squad.NO_TARGET:
			_acquire_count += 1  # 首次捕获，不算"切换"
		else:
			_switch_count += 1
		squad.target_id = new_id
		squad.target_switches += 1
	for member in members:
		member.target_id = new_id


# ---------------------------------------------------------------- 失效处理


## 每 tick 的廉价校验：目标单位已经死了 / 被清出会话 → 立刻清空共享目标。
## 这是"目标死亡自动失效"的落地位置（ADR-0012 机制 #5：句柄解析，而不是谁记得清）。
func _drop_stale_targets(ctx: BattleContext) -> void:
	for squad in ctx.squads():
		if squad.target_id == Squad.NO_TARGET:
			continue
		var target := ctx.unit_by_id(squad.target_id)
		if target != null:
			continue
		if _scan_count > 0:
			_switch_count += 1  # 只有扫过靶之后才谈得上"切换"
		squad.target_id = Squad.NO_TARGET
		squad.target_switches += 1
		for member in squad.alive_units():
			member.target_id = Squad.NO_TARGET


# ---------------------------------------------------------------- 诊断


## 诊断快照。键名固定（验证场景与调试面板按名取值，不要各自另加计数器）。
##   scans         实际扫描次数（节流后）—— 验收用例 1 判它 <= 3
##   candidates    累计候选数
##   switches      目标切换次数（-1 → 有目标 不算，算首次捕获）
##   acquisitions  首次捕获次数
##   empty_squads  扫完没拿到候选的编队次
##   elapsed       距上次扫描累积的秒数
##   interval      扫描间隔（秒）
func stats() -> Dictionary:
	return {
		"scans": _scan_count,
		"candidates": _candidate_total,
		"switches": _switch_count,
		"acquisitions": _acquire_count,
		"empty_squads": _empty_squads,
		"elapsed": _elapsed,
		"interval": SCAN_INTERVAL,
	}


## 清零诊断计数（验证用例之间复用同一个 Targeting 时用；不影响编队目标）
func reset_stats() -> void:
	_scan_count = 0
	_candidate_total = 0
	_switch_count = 0
	_acquire_count = 0
	_empty_squads = 0
	_elapsed = 0.0
