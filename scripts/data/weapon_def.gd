class_name WeaponDef
extends RefCounted

## 武器数据的运行时结构（L0 数据层，见 docs/data-registry.md / ADR-0008）。
##
## 数据源：content/weapons/<id>/weapon.tbl（扫描规则见 content/weapons/weapons.tbl）。
## 装配点：scripts/battle/unit/unit_weapons.gd（UnitWeapons.build）——
## 一个机型挂哪把武器由 unit.tbl 的 [weapon] main 决定，本类只管"这把武器是什么"。
##
## 风格对齐 scripts/data/unit_def.gd：**缺必需键就 push_error + is_valid() = false，不静默兜底**。
## 兜底的后果是"数据没填"和"数据填对了"在运行时长得一模一样（ADR-0008）。
##
## 本类刻意不做：
##   - 不生成弹体、不做命中判定、不算伤害（T-2.3）。damage / projectile_speed 只是带过去。
##   - 不持有任何场景 / 资源引用（武器表现走 future 的 vfx 表）。

## 必需键（缺一即坏数据）。顺序即 missing_keys() 的报告顺序。
const REQUIRED_KEYS: Array[String] = [
	"damage",
	"range",
	"cooldown",
	"projectile_speed",
	"tracking_rate",
	"aim_tolerance",
]

## 规范键 → TBL 里允许的别名（先命中先用）
const KEY_ALIASES := {
	"damage": ["damage"],
	"range": ["range"],
	"cooldown": ["cooldown", "reload", "fire_interval"],
	"projectile_speed": ["projectile_speed", "muzzle_speed", "bullet_speed"],
	"tracking_rate": ["tracking_rate", "turn_rate", "turret_rate"],
	"aim_tolerance": ["aim_tolerance", "tolerance", "aim_cone"],
}

## 武器逻辑 ID（= content/weapons 下的目录名）
var id := ""
## 显示名（[weapon] name，缺省回落到 id）
var display_name := ""
## 单发伤害
var damage := 0.0
## 射程（米）
var range := 0.0
## 冷却（**秒**，开火后到下一次可开火）
var cooldown := 0.0
## 弹体初速（m/s，T-2.3 用）
var projectile_speed := 0.0
## 炮塔转速上限（**度/秒**）
var tracking_rate := 0.0
## 开火容差（**度**）：瞄准方向与目标的夹角 ≤ 它才能开火
var aim_tolerance := 0.0
## 本武器在 TBL 里缺失的必需键（空 = 数据完整）。读它请用 missing_keys()。
var _missing_keys := PackedStringArray()


## 从 Registry.weapon(id) 的记录解析。record 为空（未知 ID，Registry 已报错）时返回无效 def。
static func from_record(weapon_id: String, record: Dictionary) -> WeaponDef:
	var def := WeaponDef.new()
	def.id = weapon_id
	if record.is_empty():
		return def  # Registry.weapon() 已报"未知武器 ID"，这里不重复报

	var weapon: Dictionary = record.get("weapon", {})
	def.display_name = str(weapon.get("name", weapon_id))

	for canonical in REQUIRED_KEYS:
		var aliases: Array = KEY_ALIASES[canonical]
		var parsed: Variant = _read_number(weapon, aliases, weapon_id)
		if parsed == null:
			def._missing_keys.append(canonical)
			continue
		def.set(canonical, float(parsed))

	if not def._missing_keys.is_empty():
		push_error("[WeaponDef] 武器 '%s' 的 [weapon] 缺少必需键：%s（来源 %s）。坏数据不兜底。" % [
			weapon_id, ", ".join(def._missing_keys), str(record.get("source", "?"))])
	elif def.range <= 0.0 or def.cooldown <= 0.0 or def.tracking_rate <= 0.0:
		# 键在、值不合理：不进 missing_keys，由 is_valid() 拦下
		push_error("[WeaponDef] 武器 '%s' 的 range/cooldown/tracking_rate 必须为正（实际 %.1f / %.2f / %.1f）" % [
			weapon_id, def.range, def.cooldown, def.tracking_rate])
	return def


## 诊断接口：本武器在 TBL 里缺哪些必需键（空 = 完整）
func missing_keys() -> PackedStringArray:
	return _missing_keys.duplicate()


## 数据是否可用。坏数据在 UnitWeapons.build 就拦住，不允许"挂一把 0 射程的炮"。
func is_valid() -> bool:
	if id.is_empty() or not _missing_keys.is_empty():
		return false
	if range <= 0.0 or cooldown <= 0.0 or tracking_rate <= 0.0:
		return false
	if projectile_speed <= 0.0 or damage < 0.0 or aim_tolerance < 0.0:
		return false
	return true


## 炮塔转速（**弧度/秒**）。度 → 弧度的换算只在这里做。
func tracking_rate_rad() -> float:
	return deg_to_rad(tracking_rate)


## 开火容差（**弧度**）
func aim_tolerance_rad() -> float:
	return deg_to_rad(aim_tolerance)


func describe() -> String:
	var source := "TBL" if _missing_keys.is_empty() else "TBL 缺键(%s)" % ", ".join(_missing_keys)
	return "WeaponDef(%s %s dmg=%.1f range=%.0f cd=%.2fs v=%.0f track=%.0f°/s cone=%.1f° 来源=%s)" % [
		id, display_name, damage, range, cooldown, projectile_speed,
		tracking_rate, aim_tolerance, source]


## 按别名顺序找一个数值。找不到返回 null（调用方记缺键）；
## 找到但不是数字则 push_error 并返回 null（拼错了不该静默变成兜底值）。
static func _read_number(weapon: Dictionary, aliases: Array, weapon_id: String) -> Variant:
	for alias in aliases:
		var key := str(alias)
		if not weapon.has(key):
			continue
		var raw: Variant = weapon[key]
		var type := typeof(raw)
		if type == TYPE_INT or type == TYPE_FLOAT:
			return float(raw)
		push_error("[WeaponDef] 武器 '%s' 的 [weapon] %s 不是数字（实际 %s）" % [
			weapon_id, key, type_string(type)])
		return null
	return null
