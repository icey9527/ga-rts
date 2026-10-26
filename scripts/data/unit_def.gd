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
## ─── 必需键与"坏数据必须炸"（T-2.0 起）──────────────────────────────
## content/units/<id>/unit.tbl 必须写全 REQUIRED_STATS 里的每一个键。缺任意一个都算坏数据：
## 记进 missing_keys()，**push_error 列出缺了哪些**，并让 is_valid() 返回 false，
## 于是 BattleSession.spawn_unit() 直接拒绝生成 —— 不再像 S1 那样拿 DEFAULTS 静默兜底
## （兜底的后果是"数据没填"和"数据填对了"在运行时长得一模一样，见 ADR-0008）。
##
## 为什么不给"缺键"一个默认值：
##   缺 acceleration 的木船照样能开，只是慢得莫名其妙；缺 radius 的大船会穿过小行星。
##   静默降级把数据错误藏到表现层，调试成本远高于启动时一条红字。

## 必需键（缺一即坏数据）。顺序即 missing_keys() 的报告顺序；
## STAT_ALIASES 给出每个规范键在 TBL 里允许的写法（先命中先用）。
const REQUIRED_STATS: Array[String] = [
	"max_speed",
	"acceleration",
	"deceleration",
	"turn_rate_yaw",
	"turn_rate_pitch",
	"radius",
	"cruise_altitude",
	"max_hp",
]

## 规范键 → TBL 里允许的别名（先命中先用）
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

## cruise_altitude 的合法范围（米，相对本层中心的偏移）。
## 与 UnitFlight.BAND 同源（ADR-0003：三层 ±150 带）；数据层不 import 模拟层，
## 因此这里的常量与 unit_flight.gd 的 BAND 必须同步改（两者都是 150 是刻意的）。
const MAX_CRUISE_ALTITUDE := 150.0

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

## 战斗行为原型（[behavior] kind）。
## 决定单位**接近目标后怎之走位**，不同机型因此打法不同（而不是只数值不同）：
##   close_in  贴近打（默认，最简单也最不会出错）
##   standoff  保持距离（狙击/炮击：太近才后撤）
##   orbit     绕目标环绕（散弹炮艇）
##   strafe    打完换位（战斗机/拦截机）
## 缺这个键时用 close_in，不报错 —— 它是新增能力，旧数据不应因此无法加载。
var behavior_kind := "close_in"
## 本机型哪些必需键在 TBL 里缺失（空 = 数据完整）。读它请用 missing_keys()。
var _missing_keys := PackedStringArray()


## 从 Registry.unit(id) 的记录解析。record 为空（未知 ID，Registry 已报错）时返回无效 def。
##
## 缺键不做兜底：字段保持 0、进 missing_keys()、push_error 列出全部缺失键、is_valid() = false。
## 类型写错（写了键但不是数字）由 _read_number 单独报错，同样算缺键。
static func from_record(def_id: String, record: Dictionary) -> UnitDef:
	var def := UnitDef.new()
	def.id = def_id
	if record.is_empty():
		# Registry.unit() 已报"未知单位 ID"，这里不重复报，只保证 def 无效
		return def

	var stats: Dictionary = record.get("stats", {})
	var assets: Dictionary = record.get("assets", {})
	def.display_name = str(stats.get("name", def_id))
	def.model = str(assets.get("model", ""))
	var behavior: Dictionary = record.get("behavior", {})
	def.behavior_kind = str(behavior.get("kind", "close_in"))

	for canonical in REQUIRED_STATS:
		if not STAT_ALIASES.has(canonical):
			# 编程错误（REQUIRED_STATS 与 STAT_ALIASES 不同步），不是数据错误
			push_error("[UnitDef] REQUIRED_STATS 里的 '%s' 没有对应的 STAT_ALIASES 条目" % canonical)
			def._missing_keys.append(canonical)
			continue
		var aliases: Array = STAT_ALIASES[canonical]
		var parsed: Variant = _read_number(stats, aliases, def_id)
		if parsed == null:
			def._missing_keys.append(canonical)
			continue
		def.set(canonical, float(parsed))

	if not def._missing_keys.is_empty():
		push_error("[UnitDef] 机型 '%s' 的 [stats] 缺少必需键：%s（来源 %s）。坏数据不兜底，拒绝生成。" % [
			def_id, ", ".join(def._missing_keys), str(record.get("source", "?"))])
	elif absf(def.cruise_altitude) > MAX_CRUISE_ALTITUDE:
		# 超范围不进 missing_keys（键在、值不对），由 is_valid() 拦下
		push_error("[UnitDef] 机型 '%s' 的 cruise_altitude = %.1f 超出 ±%.0f 带（ADR-0003），拒绝生成。" % [
			def_id, def.cruise_altitude, MAX_CRUISE_ALTITUDE])
	return def


## 诊断接口：本机型在 TBL 里缺哪些必需键（空 = 完整）。
## 非空 ⇒ is_valid() 为 false ⇒ BattleSession 不会生成它。
func missing_keys() -> PackedStringArray:
	return _missing_keys.duplicate()


## 数据是否可用。坏数据在调用方（BattleSession.spawn_unit）就拦住，
## 不允许"生成一艘 0 速船然后永远不动"这种静默失败。
func is_valid() -> bool:
	if id.is_empty() or not _missing_keys.is_empty():
		return false
	if max_speed <= 0.0 or acceleration <= 0.0 or deceleration <= 0.0:
		return false
	if turn_rate_yaw <= 0.0 or turn_rate_pitch <= 0.0 or radius <= 0.0:
		return false
	return absf(cruise_altitude) <= MAX_CRUISE_ALTITUDE


## 把数据写进 Unit。单位换算（度/秒 → 弧度/秒）只在这里做。
## 不碰位置 / 机头 / 航线：那是生成方的输入，不是机型数据。
func apply_to(unit: Unit) -> void:
	if unit == null:
		push_error("[UnitDef] apply_to(null)：机型 %s 没有落点" % id)
		return
	if not is_valid():
		# 走到这里说明调用方没先问 is_valid()。宁可不装配，也不装配半艘船
		push_error("[UnitDef] 机型 %s 数据不完整（缺键：%s），拒绝装配" % [
			id, "无" if _missing_keys.is_empty() else ", ".join(_missing_keys)])
		return
	unit.max_speed = max_speed
	unit.acceleration = acceleration
	unit.deceleration = deceleration
	unit.turn_rate_yaw = deg_to_rad(turn_rate_yaw)
	unit.turn_rate_pitch = deg_to_rad(turn_rate_pitch)
	unit.radius = radius
	unit.cruise_altitude = cruise_altitude
	# 血量：**必须写进 Unit**。
	# Unit.hp 的默认值是 1.0（"未初始化"的意思），以前这里漏了这两行，
	# 导致每艘船出生就是 1 血 —— 任何一发弹都秒杀。玩家看到的就是
	# “敌人被打一下就死了”、“只收到两次受击播报”。
	# max_hp 在 REQUIRED_STATS 里是被校验过的，校验过了却不装配，
	# 比不校验更危险：数据看着齐全，运行时却全部是 1 血。
	unit.max_hp = max_hp
	unit.hp = max_hp
	unit.behavior_kind = StringName(behavior_kind)


## 诊断用的一行文本
func describe() -> String:
	var source := "TBL" if _missing_keys.is_empty() else \
		"TBL 缺键(%s)" % ", ".join(_missing_keys)
	return "UnitDef(%s %s speed=%.1f accel=%.1f decel=%.1f yaw=%.1f°/s pitch=%.1f°/s r=%.1f alt=%+.1f 来源=%s)" % [
		id, display_name, max_speed, acceleration, deceleration,
		turn_rate_yaw, turn_rate_pitch, radius, cruise_altitude, source]


## 在 [stats] 里按别名顺序找一个数值。找不到返回 null（调用方记缺键）；
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
