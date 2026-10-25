class_name UnitDef
extends RefCounted

## 单位数据的运行时结构（L0 数据层，见 docs/ARCHITECTURE.md「目录职责」：
## scripts/data/ = TBL 结构体定义，普通 RefCounted，非 Resource）。
##
## 职责刻意收窄成两件事：
##   1. 把 Registry 给的一条单位记录（[stats] / [assets] 节）解析成有类型、有单位的字段
##   2. apply_to(unit) 把字段写进 Unit 数据对象（**唯一**的装配点）
##
## 为什么不让 BattleSession 自己读字典：
##   同一个键的拼写（accel / acceleration / brake）只该在一处被理解。
##   单位换算（deg/s → rad/s）也只该在一处发生 —— 散到调用方就等着某天有人传了弧度。
##
## ─── 关于缺键兜底（S1 的临时状态，S2 必须消掉）────────────────────────────
## content/units/<id>/unit.tbl 目前只有 [stats] speed / max_hp / armor / shield /
## radar / cost（见 T-1.1 的占位数据）。acceleration / deceleration / turn_rate /
## radius / cruise_altitude 这些键**还没进 TBL**，而本卡不允许改 content/。
## 所以缺键时用 DEFAULTS 兜底，并把它记进 missing_stats —— 调用方（BattleSession）
## 把这个清单打出来，谁都能一眼看到"这条数据是兜底不是表里的"。
## S2 把键补进 unit.tbl 之后，DEFAULTS 应当整块删掉，而不是继续留着。
##
## 兜底值来源：docs/scale-and-units.md 的尺寸量级 + Unit 的字段默认值（护卫舰量级）。
## 它们**不是**"另一个数据源"，只是缺数据时的占位，写在数据层而不是 spawn 代码里。

## 规范键 → TBL 里允许的别名（先命中先用）。键名顺序即报告顺序。
const STAT_ALIASES := {
	"max_speed": ["speed", "max_speed"],
	"acceleration": ["acceleration", "accel"],
	"deceleration": ["deceleration", "decel", "brake"],
	"turn_rate_yaw": ["turn_rate_yaw", "turn_rate"],
	"turn_rate_pitch": ["turn_rate_pitch", "pitch_rate"],
	"radius": ["radius", "hull_radius"],
	"cruise_altitude": ["cruise_altitude", "cruise_offset"],
	"max_hp": ["max_hp"],
}

## 缺键兜底（S2 删掉，见文件头）。转速在 TBL / 本表里都是**度/秒**。
const DEFAULTS := {
	"max_speed": 180.0,
	"acceleration": 60.0,
	"deceleration": 80.0,
	"turn_rate_yaw": 30.0,
	"turn_rate_pitch": 20.0,
	"radius": 20.0,
	"cruise_altitude": 0.0,
	"max_hp": 1000.0,
}

## 机型逻辑 ID（= content/units 下的目录名）
var id := ""
## 显示名（[stats] name，缺省回落到 id）
var display_name := ""
## 最大速度（m/s）—— TBL [stats] speed
var max_speed := 0.0
## 加速度（m/s²）
var acceleration := 0.0
## 减速度（m/s²）
var deceleration := 0.0
## 机头水平转速上限（**度/秒**，apply_to 里转成 Unit 要的 rad/s）
var turn_rate_yaw := 0.0
## 机头俯仰转速上限（**度/秒**）
var turn_rate_pitch := 0.0
## XZ 半径（米）
var radius := 0.0
## 巡航高度偏好（相对层中心的偏移，米）
var cruise_altitude := 0.0
## 最大血量（S1 不参与战斗，只带过去）
var max_hp := 0.0
## 模型逻辑名（[assets] model），交给 Registry.asset() 解析 —— 代码里不出现路径
var model := ""
## 本机型哪些统计键在 TBL 里缺失、用了 DEFAULTS（空 = 全部来自表）
var missing_stats := PackedStringArray()


## 从 Registry.unit(id) 的记录解析。record 为空（未知 ID，Registry 已报错）时返回无效 def。
static func from_record(def_id: String, record: Dictionary) -> UnitDef:
	var def := UnitDef.new()
	def.id = def_id
	if record.is_empty():
		return def

	var stats: Dictionary = record.get("stats", {})
	var assets: Dictionary = record.get("assets", {})
	def.display_name = str(stats.get("name", def_id))
	def.model = str(assets.get("model", ""))

	for canonical in STAT_ALIASES.keys():
		var aliases: Array = STAT_ALIASES[canonical]
		var parsed: Variant = _read_number(stats, aliases, def_id)
		if parsed == null:
			def.missing_stats.append(str(canonical))
			def.set(canonical, float(DEFAULTS[canonical]))
			continue
		def.set(canonical, float(parsed))
	return def


## 数据是否可用（ID 有、速度为正）。坏数据在调用方（BattleSession.spawn_unit）就拦住，
## 不允许"生成一艘 0 速船然后永远不动"这种静默失败。
func is_valid() -> bool:
	return not id.is_empty() and max_speed > 0.0 and acceleration >= 0.0 \
		and deceleration >= 0.0 and radius >= 0.0


## 把数据写进 Unit。单位换算（度/秒 → 弧度/秒）只在这里做。
## 不碰位置 / 机头 / 航线：那是生成方的输入，不是机型数据。
func apply_to(unit: Unit) -> void:
	if unit == null:
		push_error("[UnitDef] apply_to(null)：机型 %s 没有落点" % id)
		return
	unit.max_speed = max_speed
	unit.acceleration = acceleration
	unit.deceleration = deceleration
	unit.turn_rate_yaw = deg_to_rad(turn_rate_yaw)
	unit.turn_rate_pitch = deg_to_rad(turn_rate_pitch)
	unit.radius = radius
	unit.cruise_altitude = cruise_altitude


## 诊断用的一行文本
func describe() -> String:
	var source := "TBL" if missing_stats.is_empty() else \
		"TBL + 兜底(%s)" % ", ".join(missing_stats)
	return "UnitDef(%s %s speed=%.1f accel=%.1f decel=%.1f yaw=%.1f°/s pitch=%.1f°/s r=%.1f alt=%+.1f 来源=%s)" % [
		id, display_name, max_speed, acceleration, deceleration,
		turn_rate_yaw, turn_rate_pitch, radius, cruise_altitude, source]


## 在 [stats] 里按别名顺序找一个数值。找不到返回 null（调用方兜底）；
## 找到但不是数字则 push_error 并返回 null（拼错了不该静默变成兜底值）。
static func _read_number(stats: Dictionary, aliases: Array, def_id: String) -> Variant:
	for alias in aliases:
		var key := str(alias)
		if not stats.has(key):
			continue
		var raw: Variant = stats[key]
		var type := typeof(raw)
		if type == TYPE_INT or type == TYPE_FLOAT:
			return float(raw)
		push_error("[UnitDef] 单位 '%s' 的 [stats] %s 不是数字（实际 %s）" % [
			def_id, key, type_string(type)])
		return null
	return null
