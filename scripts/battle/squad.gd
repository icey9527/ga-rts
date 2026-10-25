class_name Squad
extends RefCounted

## 最小编队容器（L1 模拟层，ADR-0012 机制 #1「编队级集中选靶」的载体）。
##
## 本卡只做两件事：
##   1. 按 team 把单位聚在一起（S1 没有编队指令，分组唯一依据就是队伍号）
##   2. 持有**共享目标** target_id —— 个体不各自索敌，只读这个字段
## 阵型 / 行为栈 / 编队命令归 S3（ADR-0012 机制 #2），本类刻意不预留空壳字段：
## 一个"看起来像有阵型但其实没人写"的字段比没有更难查。
##
## 为什么是 RefCounted 而不是 Node（本卡硬约束 5）：
##   编队属于模拟层，必须能脱离场景树单测；Node 会把它绑到 _process 与渲染树上。
##
## 为什么 target_id 存 id 而不是 Unit 引用（ADR-0012 机制 #5「句柄解析」）：
##   目标死亡后引用会变成"看起来还活着"的悬垂对象 —— 只要有人忘了清空，AI 就会
##   对着尸体开火。存 int id，取值一律经过 BattleContext.unit_by_id() 解析，
##   解析不到 = 目标已失效，失效是**自动**的，不依赖谁记得清空。
##   本类的 units 数组仍存 Unit 引用（同编队成员在同一 tick 内不会失效，
##   且死亡单位由 alive_units() 过滤）。

## 无效目标 id。负数 = 没有目标（Unit.id 从 1 起，0 与负数都不会撞上）
const NO_TARGET := -1


## 编队运行时 ID（由 BattleSession 分配，1 起单调递增；只用于诊断输出）
var id := 0
## 队伍号（与 Unit.team 一致；本卡编队 = 同队伍的全部单位）
var team := 0
## 成员（数组顺序 = 生成顺序；遍历顺序稳定 = 可回放）
var units: Array[Unit] = []
## 共享目标 id（NO_TARGET = 无目标）。**只有 Targeting 写它**，个体只读
var target_id := NO_TARGET
## 目标切换次数（由 Targeting 记账，本类只持有字段方便表现层读取）
var target_switches := 0


func _init(p_id: int = 0, p_team: int = 0) -> void:
	id = p_id
	team = p_team


# ---------------------------------------------------------------- 成员


## 加入一个成员（已在队里则不重复加；保留首次加入的顺序）
func add_unit(unit: Unit) -> void:
	if unit == null:
		push_error("[Squad] id=%d add_unit(null)：忽略" % id)
		return
	if units.has(unit):
		return
	units.append(unit)


## 移除一个成员（遍历中不要调它，硬规则 6：死亡的清理走 tick 第 8 步）
func remove_unit(unit: Unit) -> void:
	var at := units.find(unit)
	if at >= 0:
		units.remove_at(at)


func has_unit(unit: Unit) -> bool:
	return units.has(unit)


func size() -> int:
	return units.size()


## 存活成员（副本）。所有 AI 逻辑都用它，不要直接遍历 units —— 死亡单位还在数组里
## （物理清理走 tick 第 8 步，硬规则 6），直接用会让尸体参与选靶与状态判定。
func alive_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in units:
		if unit.alive:
			out.append(unit)
	return out


## 编队中心 = 存活成员位置的算术平均（米）。全部阵亡 → Vector3.ZERO。
## 用 position 而不是 expected_position()：编队中心是"本 tick 的观察值"，
## 拿下一 tick 的预测位置去选靶会让结果依赖调用顺序。
func center() -> Vector3:
	var alive := alive_units()
	if alive.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for unit in alive:
		sum += unit.position
	return sum / float(alive.size())


# ---------------------------------------------------------------- 目标


func has_target() -> bool:
	return target_id != NO_TARGET


func clear_target() -> void:
	target_id = NO_TARGET


func describe() -> String:
	return "Squad(id=%d team=%d 成员=%d/%d target=%d 切换=%d)" % [
		id, team, alive_units().size(), units.size(), target_id, target_switches]
