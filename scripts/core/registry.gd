class_name Registry
extends RefCounted

## 数据注册表（L0 数据层，见 docs/data-registry.md / ADR-0008）。
##
## 唯一硬编码路径是下面的 BASE_TBL —— 整个代码库里只此一处。
## 其余一切（类别、扫描目录、manifest 文件名、资产路径）都从 TBL 里读。
##
## 流程：
##   1. 读 base.tbl 的 [registry] → 各类别的 TBL 相对路径
##   2. 读 [roots] → content / assets 根（缺了直接炸，不猜默认值）
##   3. 读 [mounts] → 依次 load_resource_pack(.dat)
##   4. 每个类别 TBL 里的 [type.*] 是扫描规则：dir + manifest + id_from = dirname
##   5. 扫 dir/*/manifest，解析 manifest TBL，注册
##   6. 全量校验：缺 manifest 警告跳过 / ID 重复报错 / 资产引用存在 / 必需键齐全
##   7. 写 registry_report.txt（user://）
##   8. 只读 API：units() / unit(id) / asset(逻辑名)
##
## 错误处理：坏数据必须炸（push_error + 计入 report），不允许静默降级。

## 整个代码库唯一的字面路径
const BASE_TBL := "res://content/base.tbl"
## 校验报告输出位置
const REPORT_PATH := "user://registry_report.txt"

## 类型 manifest 的必需键：{ 类型节名: { 节名: [必需键] } }
const REQUIRED_KEYS := {
	"type.unit": {"stats": ["name", "speed", "max_hp"]},
}

## 资产路径不带扩展名（引擎按导入产物找），校验时依次尝试这些扩展名
const ASSET_EXTENSIONS: Array[String] = [
	"glb", "gltf", "scn", "tscn", "res", "tres",
	"png", "jpg", "jpeg", "webp", "svg", "ogg", "wav", "mp3",
]

## 所有错误（坏数据），每条自带来源与行号（TBL 解析错误来自 Tbl.errors）
var errors := PackedStringArray()
## 所有警告（可降级项：缺 manifest 的目录、缺失的可选类别 TBL 等）
var warnings := PackedStringArray()

var _base: Tbl = null
var _content_root := ""
var _assets_root := ""
## 类别名 → 该类别 TBL（见 base.tbl 的 [registry]）
var _category_tables: Dictionary = {}
## 类别名 → 该类别 TBL 的 res:// 路径
var _category_paths: Dictionary = {}
## 类别名 → { ID → 记录字典 }
var _records: Dictionary = {}
## 资产逻辑名 → res://assets/ 下的相对路径（不含扩展名）
var _assets: Dictionary = {}
## 资产逻辑名 → 登记它的 assets.tbl 节名
var _asset_owner: Dictionary = {}
var _hot_reload := false
var _validate_on_start := true
var _loaded := false
var _report_file := ""


## 加载并校验全部数据。返回 true 表示零错误（有警告仍算成功）。
func load_all() -> bool:
	reset()
	if not _load_base():
		_write_report()
		return false
	if not _read_roots():
		_write_report()
		return false
	_read_debug_flags()
	_apply_mounts()
	_load_category_tables()
	_load_assets()
	_scan_all_categories()
	if _validate_on_start:
		_validate_assets()
	_write_report()
	_loaded = true
	return errors.is_empty()


## 清空全部状态，允许重复 load_all()
func reset() -> void:
	errors = PackedStringArray()
	warnings = PackedStringArray()
	_base = null
	_content_root = ""
	_assets_root = ""
	_category_tables = {}
	_category_paths = {}
	_records = {}
	_assets = {}
	_asset_owner = {}
	_hot_reload = false
	_validate_on_start = true
	_loaded = false
	_report_file = ""


func is_loaded() -> bool:
	return _loaded


## 报告文件的绝对路径（未生成时为空字符串）
func report_file() -> String:
	return _report_file


## 已注册单位 ID，字典序
func units() -> PackedStringArray:
	return _ids_of("units")


## 地图 ID 列表（content/maps 扫描结果），字典序
func maps() -> PackedStringArray:
	return _ids_of("maps")


## 地图记录：结构同 unit()（[map] / [obstacle.*] / [spawn.*] 的嵌套字典）
## 未知 ID → push_error 并返回空字典。解析与校验在 scripts/data/map_def.gd。
func map(id: String) -> Dictionary:
	var records: Dictionary = _records.get("maps", {})
	if not records.has(id):
		push_error("[registry] 未知地图 ID: %s" % id)
		return {}
	return (records[id] as Dictionary).duplicate(true)


## 单位记录：{"id": ..., "source": ..., 各 section 扁平展开}
## 未知 ID → push_error 并返回空字典
func unit(id: String) -> Dictionary:
	var records: Dictionary = _records.get("units", {})
	if not records.has(id):
		push_error("[registry] 未知单位 ID: %s" % id)
		return {}
	return (records[id] as Dictionary).duplicate(true)


## 逻辑名 → res:// 完整路径（不含扩展名）。找不到 → push_error + 空字符串
func asset(logical_name: String) -> String:
	if not _assets.has(logical_name):
		push_error("[registry] 未登记的资产逻辑名: %s" % logical_name)
		return ""
	return _assets_root.path_join(str(_assets[logical_name]))


## 已登记的全部资产逻辑名，字典序
func asset_names() -> PackedStringArray:
	var out := PackedStringArray()
	for name in _assets.keys():
		out.append(str(name))
	out.sort()
	return out


## 某类别的已注册 ID（"units" / "teams" / "maps" …），字典序
func ids_of(category: String) -> PackedStringArray:
	return _ids_of(category)


# ---------------------------------------------------------------- 加载阶段


func _load_base() -> bool:
	var tbl := _load_tbl(BASE_TBL)
	if tbl == null:
		_error("[base.tbl] 无法解析注册表入口 %s" % BASE_TBL)
		return false
	_base = tbl
	if not tbl.has_section("registry"):
		_error("[base.tbl] %s 缺少 [registry] 节" % BASE_TBL)
		return false
	return true


func _read_roots() -> bool:
	var content := str(_base.get_value("roots", "content", ""))
	var assets := str(_base.get_value("roots", "assets", ""))
	if content.is_empty():
		_error("[roots] 缺少 content 根路径")
		return false
	if assets.is_empty():
		_error("[roots] 缺少 assets 根路径")
		return false
	if DirAccess.open(content) == null:
		_error("[roots] content 根不存在: %s" % content)
		return false
	if DirAccess.open(assets) == null:
		_error("[roots] assets 根不存在: %s" % assets)
		return false
	_content_root = content
	_assets_root = assets
	return true


func _read_debug_flags() -> void:
	_validate_on_start = bool(_base.get_value("debug", "validate_on_start", true))
	# hot_reload 尚未实现（计划：F5 重载 content/），这里只登记，不静默当成已生效
	_hot_reload = bool(_base.get_value("debug", "hot_reload", false))
	if _hot_reload:
		_warn("[debug] hot_reload = true，但热重载尚未实现，本次仍为一次性加载")


func _apply_mounts() -> void:
	var raw: Variant = _base.get_value("mounts", "packs", [])
	var packs: Array = []
	match typeof(raw):
		TYPE_ARRAY:
			packs = raw
		TYPE_STRING:
			if not str(raw).strip_edges().is_empty():
				packs = str(raw).split(",", false)
		_:
			_error("[mounts] packs 应为数组或逗号分隔字符串")
			return
	for item in packs:
		var pack := str(item).strip_edges()
		if pack.is_empty():
			continue
		if not FileAccess.file_exists(pack):
			_warn("[mounts] 附加包不存在，跳过: %s" % pack)
			continue
		if not ProjectSettings.load_resource_pack(pack):
			_error("[mounts] 挂载失败: %s" % pack)


func _load_category_tables() -> void:
	if not _base.has_section("registry"):
		return
	var names := _base.keys_of("registry")
	if names.is_empty():
		_error("[registry] 节为空")
		return
	for name in names:
		var rel: Variant = _base.get_value("registry", name, "")
		if typeof(rel) != TYPE_STRING or str(rel).strip_edges().is_empty():
			_error("[registry] 类别 '%s' 的路径为空" % name)
			continue
		var path := _resolve_content_path(str(rel))
		if not FileAccess.file_exists(path):
			_warn("[registry] 类别 '%s' 的 TBL 不存在，跳过: %s" % [name, path])
			continue
		var tbl := _load_tbl(path)
		if tbl == null:
			continue
		_category_tables[str(name)] = tbl
		_category_paths[str(name)] = path


func _load_assets() -> void:
	var tbl: Tbl = _category_tables.get("assets", null)
	if tbl == null:
		_error("[registry] assets 类别不可用，资产引用无法校验")
		return
	for section_name in tbl.sections():
		for key in tbl.keys_of(section_name):
			var value: Variant = tbl.get_value(section_name, key, null)
			if typeof(value) != TYPE_STRING:
				continue  # 子表（如 [texture.ui] 会在 [texture] 里出现一份），跳过
			var logical := str(key)
			var rel := str(value).strip_edges()
			if rel.is_empty():
				_error("[assets] '%s' 的路径为空（节 [%s]）" % [logical, section_name])
				continue
			if _assets.has(logical):
				if str(_assets[logical]) != rel:
					_error("[assets] 逻辑名重复: '%s' → %s 与 %s（节 [%s] 与 [%s]）" % [
						logical, str(_assets[logical]), rel,
						str(_asset_owner[logical]), section_name])
				continue
			_assets[logical] = rel
			_asset_owner[logical] = section_name


func _scan_all_categories() -> void:
	for category in _category_tables.keys():
		if str(category) == "assets":
			continue
		_records[str(category)] = {}
		var tbl: Tbl = _category_tables[category]
		var type_count := 0
		for section_name in tbl.sections():
			if not section_name.begins_with("type."):
				continue
			type_count += 1
			_scan_type(str(category), section_name, tbl)
		if type_count == 0:
			# 没有 [type.*] 的类别表只当数据字典用（如 sky.tbl 的天空预设）
			warnings.append("[%s] 未声明 [type.*] 扫描规则，本次不扫描目录" % category)


func _scan_type(category: String, type_name: String, tbl: Tbl) -> void:
	var rule := tbl.section(type_name)
	var dir_rel := str(rule.get("dir", "")).strip_edges()
	var manifest := str(rule.get("manifest", "")).strip_edges()
	var id_from := str(rule.get("id_from", "dirname")).strip_edges()

	if dir_rel.is_empty():
		_error("[%s] 缺少 dir" % type_name)
		return
	if manifest.is_empty():
		_error("[%s] 缺少 manifest" % type_name)
		return
	if id_from != "dirname":
		_error("[%s] 暂只支持 id_from = dirname，实际为 '%s'" % [type_name, id_from])
		return

	var dir := _resolve_dir(dir_rel)
	var dir_access := DirAccess.open(dir)
	if dir_access == null:
		_error("[%s] 扫描目录不存在: %s" % [type_name, dir])
		return

	var subdirs: Array = []
	for sub in dir_access.get_directories():
		if str(sub).begins_with("."):
			continue
		subdirs.append(str(sub))
	subdirs.sort()

	for sub in subdirs:
		var id := str(sub)
		var manifest_path := dir.path_join(id).path_join(manifest)
		if not FileAccess.file_exists(manifest_path):
			_warn("[%s] 目录 '%s' 缺 %s，跳过: %s" % [type_name, id, manifest, manifest_path])
			continue
		var records: Dictionary = _records[category]
		if records.has(id):
			var previous := records[id] as Dictionary
			_error("[%s] ID 重复: '%s'（%s 与 %s），保留先出现的" % [
				type_name, id, str(previous.get("source", "?")), manifest_path])
			continue
		var manifest_tbl := _load_tbl(manifest_path)
		if manifest_tbl == null:
			continue
		var record := _build_record(id, manifest_path, manifest_tbl)
		if not _validate_record(category, type_name, id, record):
			continue  # 坏数据不注册，但错误已记入 report
		records[id] = record


func _build_record(id: String, source: String, tbl: Tbl) -> Dictionary:
	var record: Dictionary = {}
	for section_name in tbl.sections():
		if section_name.contains("."):
			continue  # 父节已包含子表，避免重复
		record[section_name] = tbl.section(section_name)
	record["id"] = id
	record["source"] = source
	return record


# ---------------------------------------------------------------- 校验阶段


func _validate_assets() -> void:
	var names := asset_names()
	for logical in names:
		var path := _assets_root.path_join(str(_assets[logical]))
		if not _asset_file_exists(path):
			_error("[assets] 逻辑名 '%s'（节 [%s]）指向的文件不存在: %s[.glb/.png/…]" % [
				logical, str(_asset_owner.get(logical, "?")), path])


## 校验单条记录。返回 false 表示有错误，调用方不应注册它。
func _validate_record(category: String, type_name: String, id: String, record: Dictionary) -> bool:
	var ok := true

	# 必需键
	var required: Dictionary = REQUIRED_KEYS.get(type_name, {})
	for section_name in required.keys():
		var section_data: Dictionary = record.get(section_name, {})
		if section_data.is_empty():
			_error("[%s] '%s' 缺少 [%s] 节" % [type_name, id, section_name])
			ok = false
			continue
		for key in required[section_name]:
			if not section_data.has(str(key)):
				_error("[%s] '%s' 缺少必需键 [%s] %s（来源 %s）" % [
					type_name, id, section_name, str(key), str(record.get("source", "?"))])
				ok = false

	# 资产引用是否在 assets.tbl 里登记
	var assets_section: Dictionary = record.get("assets", {})
	for key in assets_section.keys():
		var value: Variant = assets_section[key]
		if typeof(value) != TYPE_STRING:
			_error("[%s] '%s' 的 [assets] %s 应为逻辑名字符串，实际是 %s" % [
				type_name, id, str(key), type_string(typeof(value))])
			ok = false
			continue
		if not _assets.has(str(value)):
			_error("[%s] '%s' 引用未登记的资产 '%s'（[assets] %s，类别 %s）" % [
				type_name, id, str(value), str(key), category])
			ok = false

	return ok


# ---------------------------------------------------------------- 工具


func _ids_of(category: String) -> PackedStringArray:
	var out := PackedStringArray()
	var records: Dictionary = _records.get(category, {})
	for id in records.keys():
		out.append(str(id))
	out.sort()
	return out


## 读 TBL 并用 Tbl.parse_text 保留行号：
## 不走 Tbl.parse_file 是因为它出错时返回 null，行号细节会丢，报告里要带行号。
func _load_tbl(path: String) -> Tbl:
	if not FileAccess.file_exists(path):
		_error("TBL 不存在: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_error("TBL 打不开: %s (err=%d)" % [path, FileAccess.get_open_error()])
		return null
	var text := file.get_as_text()
	file.close()

	var tbl := Tbl.parse_text(text, path)
	if not tbl.errors.is_empty():
		for line in tbl.errors:
			_error(line)
		return null
	return tbl


## 类别 TBL 路径：先按 content 根解析，再兼容相对项目根的写法
func _resolve_content_path(rel: String) -> String:
	if rel.begins_with("res://"):
		return rel
	var joined := _content_root.path_join(rel)
	if FileAccess.file_exists(joined):
		return joined
	if FileAccess.file_exists(rel):
		return _scheme() + rel
	return joined


## 扫描目录：先按 content 根解析（dir = units），再兼容相对项目根的写法
## （data-registry.md 示例写的是 dir = content/units）
func _resolve_dir(rel: String) -> String:
	if rel.begins_with("res://"):
		return rel
	var joined := _content_root.path_join(rel)
	if DirAccess.open(joined) != null:
		return joined
	if DirAccess.open(rel) != null:
		return _scheme() + rel
	return joined


## "res://" 方案前缀，从 BASE_TBL 推出，避免再多写一个路径字面量
static func _scheme() -> String:
	var marker := BASE_TBL.find("://")
	return BASE_TBL.substr(0, marker + 3) if marker >= 0 else ""


func _asset_file_exists(path_no_extension: String) -> bool:
	if FileAccess.file_exists(path_no_extension):
		return true
	for extension in ASSET_EXTENSIONS:
		if FileAccess.file_exists("%s.%s" % [path_no_extension, extension]):
			return true
	return false


func _error(message: String) -> void:
	errors.append(message)
	push_error(message)


func _warn(message: String) -> void:
	warnings.append(message)
	push_warning(message)


# ---------------------------------------------------------------- 报告


func _write_report() -> void:
	var lines := PackedStringArray()
	lines.append("================================================================")
	lines.append(" registry_report.txt —— 数据注册表校验报告")
	lines.append(" 入口: %s" % BASE_TBL)
	lines.append(" 内容根: %s" % ("(未解析)" if _content_root.is_empty() else _content_root))
	lines.append(" 资产根: %s" % ("(未解析)" if _assets_root.is_empty() else _assets_root))
	lines.append(" 校验: %s   hot_reload: %s" % [
		"on" if _validate_on_start else "off",
		"on（未实现）" if _hot_reload else "off"])
	lines.append("================================================================")
	lines.append("")
	lines.append("[统计]")
	lines.append("  类别数    : %d" % _category_tables.size())
	var total_ids := 0
	for category in _records.keys():
		total_ids += (_records[category] as Dictionary).size()
	lines.append("  注册对象  : %d" % total_ids)
	lines.append("  资产数    : %d" % _assets.size())
	lines.append("  错误数    : %d" % errors.size())
	lines.append("  警告数    : %d" % warnings.size())
	lines.append("")

	lines.append("[类别]")
	for category in _category_tables.keys():
		var tbl: Tbl = _category_tables[category]
		var count: int = (_records.get(category, {}) as Dictionary).size()
		lines.append("  %-8s %-24s %-36s 已注册 %d" % [
			str(category), _types_of(tbl), str(_category_paths.get(category, "?")), count])
	lines.append("")

	lines.append("[已注册对象]")
	for category in _records.keys():
		var records: Dictionary = _records[category]
		for id in _ids_of(str(category)):
			var record: Dictionary = records[id]
			lines.append("  %-8s %-16s %s" % [str(category), id, str(record.get("source", "?"))])
	if _records.is_empty():
		lines.append("  (空)")
	lines.append("")

	lines.append("[资产抽样]")
	var names := asset_names()
	var sample_count := mini(5, names.size())
	for i in sample_count:
		lines.append("  %-14s → %s" % [names[i], _assets_root.path_join(str(_assets[names[i]]))])
	if names.is_empty():
		lines.append("  (空)")
	lines.append("")

	lines.append("[错误] (%d)" % errors.size())
	if errors.is_empty():
		lines.append("  无")
	else:
		for i in errors.size():
			lines.append("  %d) %s" % [i + 1, errors[i]])
	lines.append("")

	lines.append("[警告] (%d)" % warnings.size())
	if warnings.is_empty():
		lines.append("  无")
	else:
		for i in warnings.size():
			lines.append("  %d) %s" % [i + 1, warnings[i]])

	var file := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if file == null:
		push_error("[registry] 报告写入失败 %s (err=%d)" % [REPORT_PATH, FileAccess.get_open_error()])
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()
	_report_file = ProjectSettings.globalize_path(REPORT_PATH)


func _types_of(tbl: Tbl) -> String:
	var types := PackedStringArray()
	for section_name in tbl.sections():
		if section_name.begins_with("type."):
			types.append(section_name)
	return ", ".join(types) if not types.is_empty() else "(无 type.*)"
