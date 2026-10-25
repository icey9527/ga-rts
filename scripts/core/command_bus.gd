extends Node

## 命令唯一入口（autoload `CommandBus`，ARCHITECTURE 硬规则 1）。
##
## 全项目唯一能改变单位指令状态的函数是 issue()。交互层 / AI / 技能 / 任务脚本
## 一律只发命令，不直接写单位字段；因此"谁赢了"只在下面一处判定。
##
## 本卡只做队列骨架：
##   issue()  → 入队 + 发 command_issued 信号
##   drain()  → Simulation 每 tick 取走整批（硬规则 2：单一更新驱动）
##
## ─── 将来的仲裁（S2）加在这里，不要散到调用方 ───────────────────────────
## 仲裁 = "这条命令该不该被接受 / 覆盖谁"，实现位置固定在本文件内部：
##   1. 规则：玩家命令覆盖自动命令；玩家命令在位期间拒绝同目标的自动命令（硬规则 1）。
##   2. 落点：在 drain() 里对每条命令调用 _arbitrate(cmd) -> bool，
##      通过才进交给 Simulation 的批次；被拒绝的命令丢弃并记原因（report/debug 用），
##      不进队列、不发信号，避免表现层播错反馈。
##   3. 需要按 unit_or_group 维度维护「当前命令来源」表（player / ai / mission），
##      这张表也只能活在本文件（或本文件持有的仲裁器 RefCounted）里，
##      不得外泄给调用方 —— 一旦调用方自己判断"我这条算不算数"，单一入口就废了。
##   4. command_issued 信号的含义是"已接受"，仲裁落地后要跟着这条语义走。

## 已接受一条命令（仲裁落地前，含义暂时是"已入队"）。
## unit_or_group: 单个单位 / 编队 / 单位列表，本卡不约束类型。
signal command_issued(unit_or_group: Variant, kind: StringName, options: Dictionary)

## 待处理命令队列。每条：{"target": Variant, "kind": StringName, "options": Dictionary}
var _pending: Array = []


## 发一条命令。返回 false 表示被本层拒绝（非法命令；将来还包括仲裁拒绝）。
func issue(unit_or_group: Variant, kind: StringName, options: Dictionary = {}) -> bool:
	if unit_or_group == null:
		push_error("[CommandBus] 命令缺少目标，kind=%s" % String(kind))
		return false
	if kind == &"":
		push_error("[CommandBus] 命令缺少 kind")
		return false
	_pending.append({
		"target": unit_or_group,
		"kind": kind,
		"options": options.duplicate(true),
	})
	command_issued.emit(unit_or_group, kind, options)
	return true


## 取走并清空待处理队列（由 Simulation 每 tick 调用一次）。
## 返回 Array[Dictionary]，元素结构同 _pending。
func drain() -> Array:
	var batch: Array = _pending
	_pending = []
	return batch


## 队列深度（调试 / 断言用）
func pending_count() -> int:
	return _pending.size()
