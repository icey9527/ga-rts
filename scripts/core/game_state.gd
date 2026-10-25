extends Node

## 全局容器（autoload `GameState`）。L1 模拟层的门面，只做装配与持有。
##
## 职责刻意保持最小（见 docs/ARCHITECTURE.md 的目录职责表）：
##   1. 构造并加载唯一一份 Registry（L0 数据层），对外只读暴露。
##      Registry 是 RefCounted，**不能直接做 autoload**，所以由本节点持有实例。
##   2. 持有「当前选中单位」占位列表（本卡只给空数组 + 最小读写口）。
##
## 本文件明确不做：
##   - 单位逻辑            → scripts/battle/unit/
##   - 每 tick 推进         → Simulation（硬规则 2：单一更新驱动）
##   - 命令写入            → CommandBus.issue()（硬规则 1：单一命令入口）
##
## 反模式提醒：GameState 不是"什么都能塞的袋子"。新加状态的默认答案是
## "放到它该在的系统里"，只有真正全局且无主的装配结果才进这里。

## L0 注册表实例（RefCounted，由本节点持有引用）
var _registry: Registry = null
## 当前选中的单位（占位）。后续卡存 Unit 引用，本卡恒为空数组。
var _selected_units: Array = []


func _ready() -> void:
	_registry = Registry.new()
	if _registry.load_all():
		print("[GameState] 数据加载完成：单位 %d，资产 %d，警告 %d" % [
			_registry.units().size(),
			_registry.asset_names().size(),
			_registry.warnings.size()])
		return
	# 坏数据必须炸：Registry 已逐条 push_error 并写了报告，这里补一条入口级错误
	push_error("[GameState] 数据加载失败（%d 个错误），详见 %s" % [
		_registry.errors.size(), _registry.report_file()])


## L0 数据层入口。加载失败时仍返回实例（errors 里有内容），不返回 null，
## 让调用方按需检查 data_ok()，避免到处 null 判断。
func registry() -> Registry:
	return _registry


## 数据是否可用（已加载且零错误）。模拟层启动前应先问这一句。
func data_ok() -> bool:
	return _registry != null and _registry.is_loaded() and _registry.errors.is_empty()


## 当前选中单位（占位）。返回内部数组本身，约定调用方只读；写入走 set_selected_units()。
func selected_units() -> Array:
	return _selected_units


## 替换选中列表（选择逻辑在 T-1.3 input 层，本卡只提供落点）。
func set_selected_units(units: Array) -> void:
	_selected_units = units
