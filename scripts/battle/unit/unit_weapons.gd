class_name UnitWeapons
extends RefCounted

## 一个单位的全部炮塔（L1 模拟层）。纯 RefCounted，不继承 Node（硬规则 2）。
##
## 职责（ADR-0012 机制 #11「两级火控」的下半层）：
##   火控中心（Targeting）**慢**（节流扫描、编队共享目标）→ 给一个目标点；
##   炮塔**快**（每 tick 自转 + 冷却推进）→ 决定"这一 tick 有几个炮塔想开火"。
## 本类只负责后者，且只报数：**不生成弹体、不做命中、不算伤害**（T-2.3）。
##
## build() 的输入全在数据里：
##   unit.tbl [weapon] main  = content/weapons/<id>/ 的目录名（不是路径）
##   count                   = 炮塔数
##   spread                  = 相邻炮塔在舰体坐标系里的错开量（米，vec3）
## 代码里没有一句"ou134 有 4 个炮塔"。
##
## 确定性：炮塔顺序 = 生成顺序，没有随机。

## 单机型炮塔数上限（防御坏数据：count = 100000 不该把内存吃光）
const MAX_MOUNTS := 16


## 装配本单位的炮塔组。unit 的 position / forward 必须已经就位。
##
## ctx 用来解析数据（ctx.registry()），不用来选靶：选靶在 Targeting，本类不碰。
## 返回的 UnitWeapons 可能是空组（数据坏 / 机型没写 [weapon]），错误已 push_error。
static func build(unit: Unit, def_id: String, ctx: BattleContext) -> UnitWeapons:
	var weapons := UnitWeapons.new()
	if unit == null:
		push_error("[UnitWeapons] build(null)：机型 %s 没有落点" % def_id)
		return weapons
	if ctx == null or ctx.registry() == null:
		push_error("[UnitWeapons] build 需要 ctx.registry()（机型 %s），拿到的是空" % def_id)
		return weapons

	var record := ctx.registry().unit(def_id)
	if record.is_empty():
		return weapons  # Registry.unit() 已报"未知单位 ID"

	var spec_raw: Variant = record.get("weapon", null)
	if typeof(spec_raw) != TYPE_DICTIONARY:
		push_error("[UnitWeapons] 机型 '%s' 的 unit.tbl 缺少 [weapon] 节（main / count / spread）" % def_id)
		return weapons
	var spec := spec_raw as Dictionary

	var weapon_id := str(spec.get("main", "")).strip_edges()
	if weapon_id.is_empty():
		push_error("[UnitWeapons] 机型 '%s' 的 [weapon] 缺少 main（武器逻辑 ID = content/weapons 的目录名）" % def_id)
		return weapons

	var count := 1
	if spec.has("count"):
		var raw_count: Variant = spec["count"]
		if typeof(raw_count) != TYPE_INT:
			push_error("[UnitWeapons] 机型 '%s' 的 [weapon] count 应为整数（写法 count:int = 2），实际 %s" % [
				def_id, type_string(typeof(raw_count))])
			return weapons
		count = int(raw_count)
	if count < 1 or count > MAX_MOUNTS:
		push_error("[UnitWeapons] 机型 '%s' 的 [weapon] count = %d 非法（允许 1..%d）" % [
			def_id, count, MAX_MOUNTS])
		return weapons

	var spread := Vector3.ZERO
	if spec.has("spread"):
		var raw_spread: Variant = spec["spread"]
		if typeof(raw_spread) != TYPE_VECTOR3:
			push_error("[UnitWeapons] 机型 '%s' 的 [weapon] spread 应为 vec3（写法 spread:vec3 = 3,0,0），实际 %s" % [
				def_id, type_string(typeof(raw_spread))])
			return weapons
		spread = raw_spread as Vector3
	elif count > 1:
		push_warning("[UnitWeapons] 机型 '%s' 有 %d 个炮塔但没写 spread：它们会重叠在同一点" % [
			def_id, count])

	var weapon_def := WeaponDef.from_record(weapon_id, ctx.registry().weapon(weapon_id))
	if not weapon_def.is_valid():
		push_error("[UnitWeapons] 机型 '%s' 的主武器 '%s' 数据不可用：%s" % [
			def_id, weapon_id, weapon_def.describe()])
		return weapons

	for i in count:
		# 以舰体中线为中心对称错开：count=4 → -1.5, -0.5, +0.5, +1.5 份 spread
		var t := float(i) - float(count - 1) * 0.5
		var mount := WeaponMount.new()
		mount.def = weapon_def
		mount.local_offset = spread * t
		mount.aim_direction = unit.forward
		weapons._mounts.append(mount)
	return weapons


## 全部炮塔（副本；炮塔对象本身是引用，改字段会直接影响模拟 —— 约定只读）
## 全部炮塔里最远的有效射程（米）。没有炮塔返回 0。
##
## 为什么单独有这个方法：unit.tbl 的 [weapon] range 是个笼统的「交战距离」，
## 与本机型实际挂载的武器射程并不一致 ——
##   ou05  写 1800，但脉冲炮只有 700
##   ou134 未写（默认值），但重炮有 2000
## 追击必须压到**真能开火**的距离，否则会停在「状态机认为在射程内、
## 炮塔却够不着」的空档里，双方永远对望。
func max_range() -> float:
	var best := 0.0
	for mount in _mounts:
		if mount.def != null:
			best = maxf(best, mount.def.range)
	return best


func mounts() -> Array[WeaponMount]:
	var out: Array[WeaponMount] = []
	out.append_array(_mounts)
	return out


func mount_count() -> int:
	return _mounts.size()


## 手工挂一个炮塔（验证场景 / 将来装配特殊挂点用；build() 走同一份数据）
func add_mount(mount: WeaponMount) -> void:
	if mount == null:
		push_error("[UnitWeapons] add_mount(null)：忽略")
		return
	_mounts.append(mount)


## 推进所有炮塔的瞄准与冷却，**返回本 tick "想开火"的炮塔数**。
## 想开火的炮塔当场扣冷却（否则同一 tick 内重复调用会重复计数）。
## 真正的弹体在 T-2.3 生成 —— 本函数不碰任何弹道。
func tick(unit: Unit, target_pos: Vector3, dt: float) -> int:
	if unit == null:
		push_error("[UnitWeapons] tick(null)：忽略")
		return 0
	if dt <= 0.0 or not is_finite(dt):
		push_error("[UnitWeapons] dt 非法（%f），跳过本次炮塔推进" % dt)
		return 0
	if not target_pos.is_finite():
		push_error("[UnitWeapons] target_pos 不是有限坐标（%s），跳过本次炮塔推进" % str(target_pos))
		return 0
	var ready := 0
	for mount in _mounts:
		mount.tick_cooldown(dt)
		mount.aim_at(unit, target_pos, dt)
		if mount.can_fire(unit, target_pos):
			mount.consume_cooldown()
			ready += 1
	return ready


## 只推进冷却（没有目标时用：炮塔不转，但冷却照样走完，不能靠"没有目标"白嫖冷却）
func tick_cooldowns(dt: float) -> void:
	if dt <= 0.0 or not is_finite(dt):
		return
	for mount in _mounts:
		mount.tick_cooldown(dt)


func describe() -> String:
	var ids := PackedStringArray()
	for mount in _mounts:
		ids.append("?" if mount.def == null else mount.def.id)
	return "UnitWeapons(%d 门：%s)" % [_mounts.size(), ", ".join(ids) if ids.size() > 0 else "无"]


## 炮塔列表（内部用；build/tick 都走它，避免到处复制数组）
var _mounts: Array[WeaponMount] = []
