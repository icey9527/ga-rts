extends Node

## 固定步长驱动（autoload `Simulation`，ARCHITECTURE 硬规则 2 / 3）。
##
## 唯一推动模拟前进的地方。任何单位都**不得**在自己的 _process/_physics_process
## 里推进自己；全部由本节点按固定步长 tick，一处驱动才可能单测与回放。
##
## 本卡只有累加器 + 九步顺序的空壳：
##   每 tick 现在真正做的只有两件事 —— 排空 CommandBus、发 ticked 信号。
##   逻辑在 S1/S2 填；**不要在骨架里顺手塞逻辑**，塞进去就没人再挪出来了。
##
## 固定顺序见 docs/ARCHITECTURE.md「模拟循环顺序（每 tick，固定顺序不得打乱）」。

## 一个 tick 走完（tick_index 从 1 开始单调递增）
signal ticked(tick_index: int)

## 模拟频率（Hz）。60 与物理帧一致：本卡用 _physics_process 做累加器。
const TICK_RATE := 60
## 单 tick 秒数
const TICK_SECONDS := 1.0 / float(TICK_RATE)
## 一帧最多补跑几个 tick（掉帧保护：卡顿后不追尾到死）
const MAX_TICKS_PER_FRAME := 8

## 未消费的累计时间
var _accumulator := 0.0
## 已完成的 tick 数（ticked 信号里给的是这个值）
var _tick_index := 0


func _physics_process(delta: float) -> void:
	_accumulator += delta
	var steps := 0
	while _accumulator >= TICK_SECONDS and steps < MAX_TICKS_PER_FRAME:
		_accumulator -= TICK_SECONDS
		steps += 1
		tick()
	if steps == MAX_TICKS_PER_FRAME:
		# 追不上就丢掉积压时间，否则下一帧要补更多，进入螺旋死亡
		_accumulator = 0.0


## 走一个固定步长。顺序固定，不得打乱、不得合并。
func tick() -> void:
	_step_commands()        # 1
	_step_clock()           # 2
	_step_units()           # 3
	_apply_accumulators()   # 4
	_step_projectiles()     # 5
	_dispatch_hits()        # 6
	_step_skills()          # 7
	_resolve_requests()     # 8
	_publish_snapshot()     # 9

	_tick_index += 1
	ticked.emit(_tick_index)


## 已完成的 tick 数
func tick_index() -> int:
	return _tick_index


# ---------------------------------------------------------------- 九步（骨架）
#
# 每一步都保持空实现 + TODO（写明归哪张卡 / 谁负责），
# 让"顺序"这条硬规则在代码里看得见，而不是只活在文档里。


## 1. 命令队列 flush。仲裁在 CommandBus 内部完成，这里只取走已接受的结果。
func _step_commands() -> void:
	var batch := CommandBus.drain()
	if batch.is_empty():
		return
	# TODO(T-1.5/S2)：逐条分发给目标单位 / 编队的行为栈。


## 2. 全局时钟 / 经济 / 任务目标 / 帧对比触发器判定。
func _step_clock() -> void:
	# TODO(T-1.x mission)：推进全局时钟，交由 scripts/systems/mission/ 判定触发器。
	pass


## 3. 每单位：行为栈 / 状态机决策 → 索敌 → 移动累积 → 武器冷却 → 开火请求。
##    注意这里只写 accum_* 期望增量，不得直接改 position/rotation。
func _step_units() -> void:
	# TODO(T-1.5)：遍历单位，只写 accum_position / accum_rotation / accum_speed。
	pass


## 4. 累加器统一应用：位置 / 朝向 / 速度一次性写回，然后清零（硬规则 3）。
func _apply_accumulators() -> void:
	# TODO(T-1.5)：统一应用增量并清零，状态切换不留残余速度（ADR-0012）。
	pass


## 5. 弹体推进 + 扫掠命中检测（ADR-0013：只做线段扫掠，不做点碰撞）。
func _step_projectiles() -> void:
	# TODO(S2)：ShapeCast3D 扫掠「上一 tick 位置 → 当前位置」。
	pass


## 6. 命中信号派发 → 目标侧结算伤害（弹体不修改目标状态）。
func _dispatch_hits() -> void:
	# TODO(S2)：派发命中信号，伤害由目标侧结算。
	pass


## 7. 技能任务 tick。
func _step_skills() -> void:
	# TODO(S3)：scripts/battle/skills/ 的任务推进。
	pass


## 8. 请求表结算（死亡清理、生成）。遍历中不改集合，增删都走请求表（硬规则 6）。
func _resolve_requests() -> void:
	# TODO(T-1.5)：延迟队列统一结算，不用裸 remove。
	pass


## 9. 胜负判定 → 快照发布（表现层只读这份快照做插值渲染，硬规则 4）。
func _publish_snapshot() -> void:
	# TODO(S1 联调)：发布只读快照供 L2 插值。
	pass
