class_name UnitStates
extends RefCounted

## 个体状态机（ADR-0012：**个体层用状态机，编队层用行为栈**）。
##
## 为什么个体不是行为栈：原版的 deque<CAI*> 是给"编队决策"用的；单机体的状态迁移
## 就那么几条边，上行为栈等于让"它现在在干嘛"变成一次运行时栈回溯（ADR-0012「代价」段
## 已经警告过这一点）。所以：
##   编队层（S3）  可抢占行为栈
##   个体层（本类）状态机
##
## 本卡只有 4 个状态（ADR-0012 提到"约 10 个状态"，剩下的归战斗 / 后勤卡）：
##   IDLE      没有航线，也没有目标 → 停着 / 巡航维持
##   MOVING    有航线且在飞
##   ATTACKING 有射程内目标且在打（本卡不实现开火，只切状态）
##   FOLLOWING 跟随编队（S3 阵型卡实现，本卡只保留"没有跟随目标就退回 IDLE"）
##
## 转移规则（验收用例 4 逐条对应）：
##   IDLE      → MOVING    有航线且未走完
##   MOVING    → ATTACKING 途中发现射程内敌人，且本单是 attack_move 模式
##   MOVING    → IDLE      到达航线终点
##   ATTACKING → IDLE      目标死亡 / 丢失（或跑出射程 × LOSE_RANGE_FACTOR）
##   FOLLOWING → IDLE      跟随目标失效（S3 前恒成立）
##
## **只写 unit 的状态字段**（state / state_time / state_changes），
## 不碰 position / forward / speed / accum_* —— 位移永远只由 UnitMovement 写（硬规则 3）。
## 状态切换时清一次累加器（ADR-0012「状态切换不留残余速度」）：清 accum_* 是
## 状态机的合法动作，因为它写的是增量而不是位置。

## 个体状态
enum State {
	IDLE = 0,
	MOVING = 1,
	ATTACKING = 2,
	FOLLOWING = 3,
}

## 射程失效的滞回系数：目标跑出 射程 × 1.25 才算"丢失"。
## 没有滞回的话，目标正好卡在射程边界上时状态会每 tick 抖一次
## （ATTACKING → IDLE → MOVING → ATTACKING ...），日志与表现层都会疯。
const LOSE_RANGE_FACTOR := 1.25

## 状态名（日志 / 验证输出用；不要用 str(State) —— 那是数字）
const STATE_NAMES := {
	State.IDLE: "IDLE",
	State.MOVING: "MOVING",
	State.ATTACKING: "ATTACKING",
	State.FOLLOWING: "FOLLOWING",
}


## 走一个 tick 的状态决策。调它之前必须已经有过一次攻防模式写入（Unit.attack_move）。
static func step(unit: Unit, ctx: BattleContext, dt: float) -> void:
	if unit == null:
		push_error("[UnitStates] unit 为 null，跳过本次状态决策")
		return
	if dt <= 0.0 or not is_finite(dt):
		push_error("[UnitStates] dt 非法（%f），跳过本次状态决策" % dt)
		return
	if not unit.alive:
		return

	unit.state_time += dt

	match unit.state:
		State.IDLE:
			_step_idle(unit)
		State.MOVING:
			_step_moving(unit, ctx)
		State.ATTACKING:
			_step_attacking(unit, ctx)
		State.FOLLOWING:
			_step_following(unit)
		_:
			push_error("[UnitStates] unit %d 的状态 %s 非法，重置为 IDLE" % [
				unit.id, str(unit.state)])
			_transition(unit, State.IDLE)


# ---------------------------------------------------------------- 各状态


## IDLE：有活就接。
## 注意顺序：先看航线（移动是玩家命令的直接结果），再看跟随（S3）。
static func _step_idle(unit: Unit) -> void:
	if unit.has_active_waypoint():
		_transition(unit, State.MOVING)


## MOVING：到站就停，途中遇敌就转攻击（仅 attack_move 模式）。
## 为什么普通 cmd_move 不转攻击：玩家下达"移动到 A"的语义是"别管闲事过去"，
## 自己拐去打一架会让人觉得命令不听话。区别对待由命令层写进 unit.attack_move。
static func _step_moving(unit: Unit, ctx: BattleContext) -> void:
	if unit.is_route_finished() or not unit.has_active_waypoint():
		_transition(unit, State.IDLE)
		return
	if not unit.attack_move:
		return
	if _target_in_range(unit, ctx, 1.0):
		_transition(unit, State.ATTACKING)


## ATTACKING：目标没了就退。本卡不开火（武器归 S2），所以只有"退"这一条边。
static func _step_attacking(unit: Unit, ctx: BattleContext) -> void:
	if not _target_in_range(unit, ctx, LOSE_RANGE_FACTOR):
		_transition(unit, State.IDLE)


## FOLLOWING：跟随目标（S3 阵型）。本卡没有跟随目标 → 立刻退回 IDLE。
static func _step_following(unit: Unit) -> void:
	if unit.has_active_waypoint():
		# 跟随产生的航线也走 MOVING 那一套；S3 接真阵型时这里换成编队槽位
		_transition(unit, State.MOVING)
		return
	_transition(unit, State.IDLE)


# ---------------------------------------------------------------- 判定


## 当前目标是否在（滞回后的）射程内。目标 id 由 Targeting 集中写入。
## 目标死亡 / 被清出会话 → BattleContext.unit_by_id 返回 null → 这里直接判失效，
## 不依赖任何"死亡回调"（ADR-0012 机制 #5）。
static func _target_in_range(unit: Unit, ctx: BattleContext, tolerance: float) -> bool:
	if ctx == null:
		return false
	var target := ctx.unit_by_id(unit.target_id)
	if target == null:
		return false
	var range_limit := unit.weapon_range * tolerance
	return unit.position.distance_squared_to(target.position) <= range_limit * range_limit


# ---------------------------------------------------------------- 转移


## 换状态：写 state / state_time / state_changes，并清一次累加器
## （ADR-0012「状态切换不留残余速度」；清增量 ≠ 改位置，不违反硬规则 3）。
static func _transition(unit: Unit, next: State) -> void:
	if unit.state == next:
		return
	unit.state = next
	unit.state_time = 0.0
	unit.state_changes += 1
	unit.reset_accumulators()


## 状态名（日志用）
static func state_name(state: int) -> String:
	return str(STATE_NAMES.get(state, "UNKNOWN(%d)" % state))
