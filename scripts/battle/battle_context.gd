class_name BattleContext
extends RefCounted

## AI 层的**只读**上下文（L1 模拟层）。
##
## 为什么需要它（而不是让状态机 / 索敌直接摸 BattleSession）：
##   1. 依赖方向：AI 只该知道「有哪些单位 / 有哪些编队 / 现在是第几 tick」，
##      不该知道 BattleSession 的命令队列、寻路服务、障碍传播、诊断计数 —— 一旦
##      AI 能调 session.handle_command()，硬规则 1（单一命令入口）就名存实亡。
##   2. 可测性：verify_ai 里可以直接 new 一个 BattleContext 塞几个手搓单位，
##      不需要注册表、不需要命令总线、不需要场景。
##   3. 快照语义：会话每 tick 开头 sync() 一次，AI 看到的是**同一份**视图，
##      不会出现"遍历到一半集合变了"（硬规则 6 的同一条精神）。
##
## 只读约定是**约定**不是语言保证（GDScript 没有 const 引用）：
## 拿到 Array[Unit] 副本后改数组本身无害，但改 Unit 字段就是越过边界了。
## 唯一允许 AI 写的 Unit 字段是 state / target_id / accum_*（见各文件头）。
##
## 本类刻意不做：
##   - 不持有 BattleSession（哪怕只是 WeakRef：那等于把门开回来）
##   - 不做空间索引 / 空间哈希（ADR-0013 的 sensor 层，卡在 S2）
##   - 不做可见性 / 战争迷雾（待定事项）

## 默认随机源种子。固定值 = 同输入两次跑出同结果（验收用例 6）。
## 目前没有 AI 逻辑用随机（概率化机动是 ADR-0012 机制 #12，后续卡），
## 但接口先就位，免得将来各处自己 new 一个未播种的生成器。
const DEFAULT_SEED := 20260701


## 本会话全部单位（**副本**，顺序 = 生成顺序）
var _units: Array[Unit] = []
## 本会话全部编队（**副本**）
var _squads: Array[Squad] = []
## 当前 tick 序号（0 = 还没走过 tick）
var _tick_index := 0
## AI 专用随机源（不会碰全局 randi，避免表现层取随机数影响模拟可回放性）
var _rng := RandomNumberGenerator.new()
## L0 数据注册表（**只读**；装配炮塔 / 后续技能需要按逻辑 ID 查数据）。
## 与“不持有 BattleSession”不矛盾：Registry 是纯数据表，没有命令入口。
var _registry: Registry = null


## 绑定数据注册表（BattleSession.setup 调一次）。
func bind_registry(registry: Registry) -> void:
	_registry = registry


## 数据注册表（未绑定时为 null —— 调用方必须处理）
func registry() -> Registry:
	return _registry


func _init() -> void:
	_rng.seed = DEFAULT_SEED


## 刷新视图（BattleSession 每 tick 第 1.5 步调一次；验证场景在构造后调一次）。
## 传进来的数组会被**浅拷**，调用方之后改自己的数组不影响本视图。
func sync(units: Array[Unit], squads: Array[Squad], p_tick_index: int) -> void:
	_units.clear()
	_units.append_array(units)
	_squads.clear()
	_squads.append_array(squads)
	_tick_index = p_tick_index


# ---------------------------------------------------------------- 查询


## 某队伍的所有敌方存活单位（副本）。
## 返回顺序 = 单位生成顺序，因此同样的输入必然得到同样的候选序列（可回放）。
func enemies_of(team: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in _units:
		if not unit.alive or unit.team == team:
			continue
		out.append(unit)
	return out


## 某队伍的所有友方存活单位（副本，含自己）。选择 / 编队逻辑用。
func allies_of(team: int) -> Array[Unit]:
	var out: Array[Unit] = []
	for unit in _units:
		if unit.alive and unit.team == team:
			out.append(unit)
	return out


## 按运行时 id 解析单位（ADR-0012 机制 #5「句柄解析」）。
## 返回 null = 目标已失效（死亡后被 tick 第 8 步清出会话，或者从来就没有这个 id）。
## **调用方必须处理 null**：这正是"目标死亡自动失效"不需要谁记得清空的机制来源。
func unit_by_id(id: int) -> Unit:
	if id <= 0:
		return null
	for unit in _units:
		if unit.id == id:
			return unit if unit.alive else null
	return null


## 全部编队（副本）
func squads() -> Array[Squad]:
	var out: Array[Squad] = []
	out.append_array(_squads)
	return out


## 某队伍的编队（本卡一队一编队，返回数组是为了 S3 多编队不必改签名）
func squads_of_team(team: int) -> Array[Squad]:
	var out: Array[Squad] = []
	for squad in _squads:
		if squad.team == team:
			out.append(squad)
	return out


## 单位所属编队。找不到 → null（编队按 team 自动生成，正常不会缺）
func squad_of(unit: Unit) -> Squad:
	if unit == null:
		return null
	for squad in _squads:
		if squad.has_unit(unit):
			return squad
	return null


func tick_index() -> int:
	return _tick_index


## AI 随机源（**共享**：同一 tick 内多次取数必须是同一条序列，否则不可回放）
func rng() -> RandomNumberGenerator:
	return _rng


func unit_count() -> int:
	return _units.size()


func squad_count() -> int:
	return _squads.size()


func describe() -> String:
	return "BattleContext(tick=%d 单位=%d 编队=%d)" % [_tick_index, _units.size(), _squads.size()]
