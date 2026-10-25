class_name MapDef
extends RefCounted

## 地图数据的运行时结构（L0 数据层，见 docs/ARCHITECTURE.md「目录职责」：
## scripts/data/ = TBL 结构体定义，普通 RefCounted，非 Resource）。
##
## 数据源：content/maps/<id>/map.tbl（[type.map] 的扫描规则见 content/maps/maps.tbl）。
## 装配点：scripts/battle/battle.gd —— 它把这里读出来的圆柱变成 NavObstacle、
## 把 spawn 变成 BattleSession.spawn_unit()，代码里不再出现任何坐标字面量。
##
## 为什么障碍只存「圆柱」而不是网格：
##   寻路层（ADR-0004）眼里一切障碍都是 XZ 圆柱（圆心 + 半径 + 上下两个高度），
##   多存一个面都是负担。地图表里的 pos / radius / top / bottom 正好就是这套词。
##
## 本类刻意不做：
##   - 不 import 导航层（NavObstacle 属于 L1 模拟层）。数据层只描述"是什么"，
##     "怎么变成寻路用的柱子"是 battle.gd 的接线职责。
##   - 不静默兜底：缺键 / 类型错 / 引用不存在的机型 / 层号越界 → 记 errors + push_error，
##     is_valid() 为 false（ADR-0008「坏数据必须炸」）。

# ---------------------------------------------------------------- 分层的常量
#
# 与 ADR-0003 / docs/scale-and-units.md 的高度分层表一一对应。数据层不 import
# UnitFlight（那是 L1），所以层高在这里也有一份；改层距 = 改两处 + 开 ADR。

## 层号 → 层中心高度（米）
const LAYER_CENTERS := {0: -400.0, 1: 0.0, 2: 400.0}
## 合法层号
const LAYERS: Array[int] = [0, 1, 2]
## 每层容差带半宽（米）。与 UnitFlight.BAND 同源（ADR-0003：±150）
const LAYER_BAND := 150.0


## 一个障碍：XZ 平面上的圆柱（NavObstacle 的数据源，字段一一对应）
class Obstacle extends RefCounted:
	## 节名（[obstacle.<名字>] 的 <名字>），诊断输出用
	var name := ""
	## 柱轴线上的一点（只有 X / Z 参与寻路，见 NavObstacle 的文件头）
	var position := Vector3.ZERO
	## XZ 半径（米，不含膨胀）
	var radius := 0.0
	## 柱顶高度（米）。cruise 高度 >= 柱顶 = 该障碍在这层不挡路
	var top_y := 0.0
	## 柱底高度（米）
	var bottom_y := 0.0

	func is_valid() -> bool:
		return radius >= 0.0 and top_y > bottom_y and position.is_finite()

	func describe() -> String:
		return "Obstacle(%s center=(%.1f, %.1f) r=%.1f y=[%.1f, %.1f])" % [
			name, position.x, position.z, radius, bottom_y, top_y]


## 一个初始单位（[spawn.<名字>]）
class Spawn extends RefCounted:
	## 节名，诊断输出用
	var name := ""
	## 机型逻辑 ID（= content/units 下的目录名，不是路径）
	var unit_id := ""
	## 队伍号（占位：队伍数据还没建，这里只记录）
	var team := 0
	## 世界坐标（米）
	var position := Vector3.ZERO
	## 所在高度层（0=L0 / 1=L1 / 2=L2）
	var layer := 1

	func describe() -> String:
		return "Spawn(%s unit=%s team=%d layer=%d pos=(%.1f, %.1f, %.1f))" % [
			name, unit_id, team, layer, position.x, position.y, position.z]


## 地图逻辑 ID（= content/maps 下的目录名）
var id := ""
## 显示名（[map] name）
var display_name := ""
## 默认高度层（[map] layer，0/1/2）
var layer_default := 1
## 天空逻辑名（[map] sky，查 assets.tbl）
var sky := ""
## 进场机位焦点（[map] focus，世界坐标）
var focus := Vector3.ZERO
## 进场机位距离（[map] distance，米）
var camera_distance := 0.0
## 障碍（表里的书写顺序 = 数组顺序，可回放）
var obstacles: Array[Obstacle] = []
## 初始单位
var spawns: Array[Spawn] = []
## 坏数据（每条自带节名）。非空 = 这张地图不能用
var errors := PackedStringArray()
## 可疑但可继续的情况（如没有障碍 / 没有单位）
var warnings := PackedStringArray()


## 从 Registry.map(id) 的记录解析。record 为空（未知 ID，Registry 已报错）时返回无效 MapDef。
##
## registry 用来做引用校验（spawn 的 unit 是否已注册、sky 是否有对应资产）。
## 传 null 只跳过引用校验，不跳过结构校验。
static func from_record(map_id: String, record: Dictionary, registry: Registry = null) -> MapDef:
	var map := MapDef.new()
	map.id = map_id
	if record.is_empty():
		map._fail("[map.tbl]", "地图记录为空（未知地图 ID '%s'？Registry 已报错）" % map_id)
		return map
	map._parse_header(record, registry)
	map._parse_obstacles(record)
	map._parse_spawns(record, registry)
	return map


## 层号 → 层中心高度（米）。非法层号 → 0 并 push_error（调用方应先用 layer_is_valid 校验）
static func layer_center(layer: int) -> float:
	if not LAYER_CENTERS.has(layer):
		push_error("[MapDef] 非法层号 %d（只允许 0=L0 / 1=L1 / 2=L2）" % layer)
		return 0.0
	return float(LAYER_CENTERS[layer])


## 层号是否合法
static func layer_is_valid(layer: int) -> bool:
	return LAYERS.has(layer)


## 该层的容差带：pos.y 必须落在带内才算"属于这一层"（ADR-0003）
static func layer_band(layer: int) -> Vector2:
	var center := layer_center(layer)
	return Vector2(center - LAYER_BAND, center + LAYER_BAND)


func is_valid() -> bool:
	return errors.is_empty() and not id.is_empty()


func has_warnings() -> bool:
	return not warnings.is_empty()


func obstacle_count() -> int:
	return obstacles.size()


func spawn_count() -> int:
	return spawns.size()


## 该层高度上会挡路的障碍数（battle.gd / 探针用来验证高度分层的数据是否真的分了层）
func blocking_obstacle_count(layer: int) -> int:
	var height := layer_center(layer)
	var count := 0
	for obstacle in obstacles:
		if height > obstacle.bottom_y and height < obstacle.top_y:
			count += 1
	return count


func describe() -> String:
	return "MapDef(%s %s layer=%d 障碍 %d 单位 %d sky=%s)" % [
		id, display_name, layer_default, obstacles.size(), spawns.size(), sky]


# ---------------------------------------------------------------- 解析


func _parse_header(record: Dictionary, registry: Registry) -> void:
	var raw: Variant = record.get("map", null)
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("[map]", "缺少 [map] 节（name / layer / sky / focus / distance 都写在这里）")
		return
	var section := raw as Dictionary
	display_name = _read_string(section, "name", "[map]")
	layer_default = _read_int(section, "layer", "[map]")
	sky = _read_string(section, "sky", "[map]")
	focus = _read_vec3(section, "focus", "[map]")
	camera_distance = _read_float(section, "distance", "[map]")

	if not layer_is_valid(layer_default):
		_fail("[map]", "layer = %d 非法（只允许 0=L0 / 1=L1 / 2=L2，见 ADR-0003）" % layer_default)
	if camera_distance <= 0.0:
		_fail("[map]", "distance 必须为正（实际 %f）" % camera_distance)
	if not focus.is_finite():
		_fail("[map]", "focus 不是有限坐标：%s" % str(focus))
	if not sky.is_empty() and registry != null and not registry.asset_names().has(sky):
		_fail("[map]", "sky = '%s' 不是 assets.tbl 里登记的资产逻辑名" % sky)


func _parse_obstacles(record: Dictionary) -> void:
	var raw: Variant = record.get("obstacle", null)
	if raw == null:
		_warn("没有 [obstacle.*] 节：这张地图是空场（不是错误，确认一下是不是漏了）")
		return
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("[obstacle]", "应为 [obstacle.<名字>] 子节，实际是 %s" % type_string(typeof(raw)))
		return
	var section := raw as Dictionary
	for key in section.keys():
		var entry_name := str(key)
		var context := "[obstacle.%s]" % entry_name
		var fields_raw: Variant = section[key]
		if typeof(fields_raw) != TYPE_DICTIONARY:
			_fail(context, "应为子节（[obstacle.%s] 下面写 pos / radius / top / bottom），实际是 %s" % [
				entry_name, type_string(typeof(fields_raw))])
			continue
		var fields := fields_raw as Dictionary
		var obstacle := Obstacle.new()
		obstacle.name = entry_name
		obstacle.position = _read_vec3(fields, "pos", context)
		obstacle.radius = _read_float(fields, "radius", context)
		obstacle.top_y = _read_float(fields, "top", context)
		obstacle.bottom_y = _read_float(fields, "bottom", context)
		if not obstacle.is_valid():
			_fail(context, "数据不自洽（需 radius ≥ 0 且 top > bottom 且坐标有限）：%s" % obstacle.describe())
			continue
		obstacles.append(obstacle)


func _parse_spawns(record: Dictionary, registry: Registry) -> void:
	var raw: Variant = record.get("spawn", null)
	if raw == null:
		_warn("没有 [spawn.*] 节：这张地图不会生成任何单位")
		return
	if typeof(raw) != TYPE_DICTIONARY:
		_fail("[spawn]", "应为 [spawn.<名字>] 子节，实际是 %s" % type_string(typeof(raw)))
		return
	var section := raw as Dictionary
	for key in section.keys():
		var entry_name := str(key)
		var context := "[spawn.%s]" % entry_name
		var fields_raw: Variant = section[key]
		if typeof(fields_raw) != TYPE_DICTIONARY:
			_fail(context, "应为子节（[spawn.%s] 下面写 unit / team / pos / layer），实际是 %s" % [
				entry_name, type_string(typeof(fields_raw))])
			continue
		var fields := fields_raw as Dictionary
		var spawn := Spawn.new()
		spawn.name = entry_name
		spawn.unit_id = _read_string(fields, "unit", context)
		spawn.team = _read_int(fields, "team", context)
		spawn.position = _read_vec3(fields, "pos", context)
		spawn.layer = _read_int(fields, "layer", context)

		if spawn.unit_id.is_empty():
			continue  # 缺键已报，不再叠加"引用不存在"的错
		if registry != null and not registry.units().has(spawn.unit_id):
			_fail(context, "unit = '%s' 不是已注册的机型（content/units/<id>/unit.tbl）" % spawn.unit_id)
			continue
		if spawn.team < 0:
			_fail(context, "team = %d 非法（不能为负）" % spawn.team)
		if not spawn.position.is_finite():
			_fail(context, "pos 不是有限坐标：%s" % str(spawn.position))
			continue
		if not layer_is_valid(spawn.layer):
			_fail(context, "layer = %d 非法（只允许 0=L0 / 1=L1 / 2=L2）" % spawn.layer)
			continue
		# pos.y 必须落在该层的容差带里：层号与高度是同一件事的两种写法，
		# 写岔了（layer=2 却 pos y=0）会让单位一生成就被 altitude 通道往回拉。
		var band := layer_band(spawn.layer)
		if spawn.position.y < band.x or spawn.position.y > band.y:
			_fail(context, "pos.y = %.1f 不在第 %d 层的容差带 [%.1f, %.1f] 内" % [
				spawn.position.y, spawn.layer, band.x, band.y])
			continue
		spawns.append(spawn)


# ---------------------------------------------------------------- 取值（带校验）


func _read_string(section: Dictionary, key: String, context: String) -> String:
	if not section.has(key):
		_fail(context, "缺少必需键 %s" % key)
		return ""
	var raw: Variant = section[key]
	if typeof(raw) != TYPE_STRING:
		_fail(context, "%s 应为字符串，实际是 %s" % [key, type_string(typeof(raw))])
		return ""
	var text := str(raw).strip_edges()
	if text.is_empty():
		_fail(context, "%s 为空" % key)
	return text


func _read_float(section: Dictionary, key: String, context: String) -> float:
	if not section.has(key):
		_fail(context, "缺少必需键 %s" % key)
		return 0.0
	var raw: Variant = section[key]
	var type := typeof(raw)
	if type != TYPE_INT and type != TYPE_FLOAT:
		_fail(context, "%s 应为数字，实际是 %s" % [key, type_string(type)])
		return 0.0
	var value := float(raw)
	if not is_finite(value):
		_fail(context, "%s 不是有限数值（%s）" % [key, str(raw)])
		return 0.0
	return value


func _read_int(section: Dictionary, key: String, context: String) -> int:
	if not section.has(key):
		_fail(context, "缺少必需键 %s（写法：%s:int = 1）" % [key, key])
		return 0
	var raw: Variant = section[key]
	if typeof(raw) != TYPE_INT:
		_fail(context, "%s 应为整数（写法：%s:int = 1），实际是 %s" % [
			key, key, type_string(typeof(raw))])
		return 0
	return int(raw)


func _read_vec3(section: Dictionary, key: String, context: String) -> Vector3:
	if not section.has(key):
		_fail(context, "缺少必需键 %s（写法：%s:vec3 = x,y,z）" % [key, key])
		return Vector3.ZERO
	var raw: Variant = section[key]
	if typeof(raw) != TYPE_VECTOR3:
		_fail(context, "%s 应为 vec3（写法：%s:vec3 = x,y,z），实际是 %s" % [
			key, key, type_string(typeof(raw))])
		return Vector3.ZERO
	return raw as Vector3


func _fail(context: String, message: String) -> void:
	var line := "%s %s" % [context, message]
	errors.append(line)
	push_error("[MapDef] 地图 '%s' %s" % [id, line])


func _warn(message: String) -> void:
	warnings.append(message)
	push_warning("[MapDef] 地图 '%s' %s" % [id, message])
