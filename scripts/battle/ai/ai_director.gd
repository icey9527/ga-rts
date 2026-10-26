class_name AIDirector
extends RefCounted

## 舰队 AI（四层，对齐原版 battle/ai/ 的分层：profiles → strategy → focus → executor）。
##
## 原来的 SimpleAI 只有一个判据："打最近的敌人"，两场战斗就能被看穿。
## 这里按原版的结构分层，每层只做一件事：
##
##   1. **战略层 Strategy**（每 4 秒）
##      双方力量 = Σ(hp + 攻击力×2)，比值 > 1.3 → aggressive，< 0.7 → defensive，
##      其余 balanced。战略决定"现在是压上去还是收缩"。
##      原版 strategy.lua:8-22 就是这个式子，这里照搬结构，只做量级换算。
##
##   2. **集火层 Focus**（每个决策 tick）
##      score = hp − 攻击力×0.5；母舰与维修额外加权（先打掉指挥与奶妈）。
##      取最低分作为全队集火目标。
##      **带滞回**：现目标还活着且没被明显超越（> HYSTERESIS）就保持不变 ——
##      否则两个分数接近的目标会让全队火力每 tick 左右横跳，输出全浪费在转向。
##      原版 focus.lua:14-31。
##
##   3. **执行层 Executor**（每个决策 tick，逐单位）
##      aggressive/balanced → 对集火目标下 cmd_attack
##      defensive 且我方偏弱 → 向后方集结点下 cmd_move（原版 retreat 的等价物）
##
##   4. **数据层 Profiles**
##      难度/性格参数集中成常量，不散在各层里。
##
## 硬规则：本类**只通过 CommandBus 下命令**，绝不直接改单位字段。
## 这样它和玩家走完全相同的命令路径，将来换更复杂的 AI 也不需要动别处。

## 决策节拍（秒）。原版 difficulty.reaction 的等价物：不给 AI 每帧决策的机会，
#  人眼才看得出"它在想"，也省 CPU。
const REACTION_INTERVAL := 0.5
## 战略审查间隔（秒）。原版 STRATEGY_INTERVAL = 4
const STRATEGY_INTERVAL := 4.0

## 力量比值阈值（原版 strategy.lua:15-19）
const AGGRESSIVE_RATIO := 1.3
const DEFENSIVE_RATIO := 0.7

## 集火滞回（原版 focus_hysteresis = 150）。
## 我们的血量量级是原版的约 13 倍（原版 180~1600，我们 1600~26000），所以同步放大。
const FOCUS_HYSTERESIS := 2000.0

## 母舰/维修的目标加权（原版 −500 / −200，同样按量级放大）
const MOTHERSHIP_BONUS := 6500.0
const REPAIR_BONUS := 3000.0

## defensive 时向后退到敌人反方向多少米
const RETREAT_DISTANCE := 2500.0

var team := 1

var _reaction_timer := 0.0
var _strategy_timer := 0.0
var _strategy := "balanced"
var _focus_id := -1
## 诊断计数
var _plans := 0
var _focus_switches := 0


func _init(p_team: int = 1) -> void:
	team = p_team


func current_strategy() -> String:
	return _strategy


func focus_target_id() -> int:
	return _focus_id


func plans() -> int:
	return _plans


func focus_switches() -> int:
	return _focus_switches


## 每个模拟 tick 调用（battle.gd 在 session.tick 之前调）
func tick(session: BattleSession, dt: float) -> void:
	if session == null or dt <= 0.0 or not is_finite(dt):
		return

	var mine := _units_of(session, team)
	if mine.is_empty():
		return
	var enemies := _enemies_of(session, team)
	if enemies.is_empty():
		return

	# 战略层：定期审查力量对比
	_strategy_timer += dt
	if _strategy_timer >= STRATEGY_INTERVAL:
		_strategy_timer = 0.0
		_review_strategy(mine, enemies)

	# 决策节拍：不到点就不决策（原版 reaction 的意义）
	_reaction_timer += dt
	if _reaction_timer < REACTION_INTERVAL:
		return
	_reaction_timer = 0.0
	_plans += 1

	# 集火层：选/保持目标
	_update_focus(enemies)
	var focus := _find_unit(enemies, _focus_id)

	# 执行层
	if _strategy == "defensive":
		_issue_retreat(session, mine, enemies)
		return
	if focus == null:
		return
	CommandBus.issue(mine, BattleSession.CMD_ATTACK,
		{"target": focus, "source": &"ai"})


# ---------------------------------------------------------------- 各层

## 战略层：双方力量比 → 战略姿态
func _review_strategy(mine: Array[Unit], enemies: Array[Unit]) -> void:
	var my_power := _fleet_power(mine)
	var enemy_power := _fleet_power(enemies)
	var ratio := my_power / maxf(enemy_power, 1.0)
	if ratio > AGGRESSIVE_RATIO:
		_strategy = "aggressive"
	elif ratio < DEFENSIVE_RATIO:
		_strategy = "defensive"
	else:
		_strategy = "balanced"


## 集火层：挑最低分目标，带滞回
func _update_focus(enemies: Array[Unit]) -> void:
	var best: Unit = null
	var best_score := INF
	for enemy in enemies:
		var score := _focus_score(enemy)
		# 同分时按 id 取小，保证确定性（不用 < 而用 <= 配合 id 比较）
		if score < best_score or (is_equal_approx(score, best_score)
				and best != null and enemy.id < best.id):
			best_score = score
			best = enemy
	if best == null:
		_focus_id = -1
		return

	var current := _find_unit(enemies, _focus_id)
	if current != null:
		# 现目标还能用，且没被明显超越 → 不换（防火力横跳）
		if _focus_score(current) <= best_score + FOCUS_HYSTERESIS:
			return

	_focus_id = best.id
	_focus_switches += 1


## 执行层（retreat）：向背离敌人的方向集结
func _issue_retreat(session: BattleSession, mine: Array[Unit], enemies: Array[Unit]) -> void:
	var my_center := _centroid(mine)
	var enemy_center := _centroid(enemies)
	var away := my_center - enemy_center
	if away.length_squared() < 1.0e-6:
		away = Vector3.FORWARD
	var rally := my_center + away.normalized() * RETREAT_DISTANCE
	CommandBus.issue(mine, BattleSession.CMD_MOVE,
		{"point": rally, "source": &"ai"})


# ---------------------------------------------------------------- 判据

## 单舰力量：血量 + 攻击力×2（原版 strategy.lua:10 的同一式子）
func _unit_power(unit: Unit) -> float:
	return unit.hp + _dps(unit) * 2.0


## 舰队力量总和
func _fleet_power(units: Array[Unit]) -> float:
	var total := 0.0
	for unit in units:
		total += _unit_power(unit)
	return total


## 集火评分：越低越优先（原版 focus.lua:7-11）
func _focus_score(enemy: Unit) -> float:
	var score := enemy.hp - _dps(enemy) * 0.5
	# 先打指挥与奶妈：这两类让敌方整体战力翻倍，不是靠血量体现的
	if enemy.def_id == "mothership":
		score -= MOTHERSHIP_BONUS
	elif enemy.def_id == "repair":
		score -= REPAIR_BONUS
	return score


## 每秒伤害代理值：把各炮塔的 damage / cooldown 加起来。
## 单位本身不存 attack_damage（伤害在武器表里），所以这里从挂载的炮塔反推。
func _dps(unit: Unit) -> float:
	if unit.weapons == null:
		return 0.0
	var total := 0.0
	for mount in unit.weapons.mounts():
		if mount.def == null:
			continue
		var cooldown := maxf(mount.def.cooldown, 0.01)
		total += mount.def.damage / cooldown
	return total


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


func _find_unit(units: Array[Unit], id: int) -> Unit:
	if id < 0:
		return null
	for unit in units:
		if unit.id == id:
			return unit
	return null


func _centroid(units: Array[Unit]) -> Vector3:
	if units.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for unit in units:
		sum += unit.position
	return sum / float(units.size())
