class_name Tbl
extends RefCounted

## TBL 文本解析器（L0 数据层，见 docs/data-registry.md 第六节 / ADR-0008）。
##
## 语法：
##   [section]            节；点号分层，[weapon.main] = section "weapon" 下的子表 "main"
##   key = value          键值；value 可为标量或数组
##   {a,b,c}              数组
##   ; ...  /  # ...      注释，到行尾（引号内的 ; # 不算注释）
##   "带 空格 的字符串"    引号保留空格
##
## 值类型：
##   不写标注 → 自动推断 bool / int / float / string
##   写了标注 → 强校验，不匹配即报错
##       key:int = 5          key:float = 1.5        key:bool = true
##       key:string = "x"     key:color = "#FFB84D"  key:vec3 = 1,2,3
##
## 错误一律带行号记录在 errors 里（格式 "<source>:<行号>: <说明>"）。
## 坏数据必须炸：解析出错时 parse_file 返回 null，并 push_error。

const TYPE_NAMES: Array[String] = ["bool", "int", "float", "string", "color", "vec3"]
const TRUE_TOKENS: Array[String] = ["true", "yes", "on"]
const FALSE_TOKENS: Array[String] = ["false", "no", "off"]

## 解析错误，每条形如 "content/units/ou05/unit.tbl:12: 重复键 'speed'"
var errors := PackedStringArray()
## 来源名（文件路径或人工指定的名字），用于错误信息
var source := ""

## 顶层节名 → 节字典；子表以嵌套字典形式存在，键名即子表名
var _sections: Dictionary = {}
## "节路径.键" → 首次出现的行号，用于重复键报错
var _key_lines: Dictionary = {}


static func parse_file(path: String) -> Tbl:
	if not FileAccess.file_exists(path):
		push_error("[tbl] 文件不存在: %s" % path)
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("[tbl] 打不开文件: %s (err=%d)" % [path, FileAccess.get_open_error()])
		return null
	var text := file.get_as_text()
	file.close()

	var tbl := parse_text(text, path)
	if not tbl.errors.is_empty():
		for line in tbl.errors:
			push_error("[tbl] " + line)
		return null
	return tbl


static func parse_text(text: String, source_name: String) -> Tbl:
	var tbl := Tbl.new()
	tbl.source = source_name
	tbl._parse(text)
	return tbl


## 节是否存在（支持点号路径："weapon.main"）
func has_section(name: String) -> bool:
	var parts := _split_section_name(name)
	if parts.is_empty():
		return false
	var node: Variant = _sections
	for part in parts:
		if typeof(node) != TYPE_DICTIONARY:
			return false
		var dict := node as Dictionary
		if not dict.has(part):
			return false
		node = dict[part]
	return typeof(node) == TYPE_DICTIONARY


## 取节内容（副本，调用方随便改）；不存在返回空字典
func section(name: String) -> Dictionary:
	var found := _lookup(name)
	if found.is_empty():
		return {}
	return found.duplicate(true)


## 取节内的值；不存在返回 default
func get_value(section_name: String, key: String, default: Variant = null) -> Variant:
	var dict := _lookup(section_name)
	if dict.has(key):
		return dict[key]
	return default


## 节内的键名（含子表名），按字典序
func keys_of(section_name: String) -> PackedStringArray:
	var dict := _lookup(section_name)
	var out := PackedStringArray()
	for key in dict.keys():
		out.append(str(key))
	out.sort()
	return out


## 全部节的全限定名（含父节与子节，如 "type"、"type.unit"），按字典序
func sections() -> PackedStringArray:
	var out := PackedStringArray()
	_collect_sections(_sections, "", out)
	out.sort()
	return out


func _parse(text: String) -> void:
	var normalized := text.replace("\r\n", "\n").replace("\r", "\n")
	var lines := normalized.split("\n")
	var current: Dictionary = {}
	var current_path := PackedStringArray()
	var in_section := false

	for i in lines.size():
		var line_no := i + 1
		var line := _strip_comment(lines[i]).strip_edges()
		if line.is_empty():
			continue

		if line.begins_with("["):
			var entered := _enter_section(line, line_no)
			if not entered.get("ok", false):
				in_section = false
				current = {}
				current_path = PackedStringArray()
				continue
			current = entered["dict"]
			current_path = entered["path"]
			in_section = true
			continue

		if not in_section:
			_err(line_no, "键值出现在任何 [section] 之前: %s" % line)
			continue

		var eq := line.find("=")
		if eq < 0:
			_err(line_no, "无法识别的行（既不是 [section] 也没有 '='）: %s" % line)
			continue

		var key_part := line.substr(0, eq).strip_edges()
		var value_part := line.substr(eq + 1).strip_edges()
		var key := key_part
		var annotation := ""

		var colon := key_part.find(":")
		if colon >= 0:
			key = key_part.substr(0, colon).strip_edges()
			annotation = key_part.substr(colon + 1).strip_edges()
			if annotation.is_empty():
				_err(line_no, "键类型标注缺少类型名: %s" % key_part)
				continue
			if key.is_empty():
				_err(line_no, "键类型标注缺少键名: %s" % key_part)
				continue
			if not TYPE_NAMES.has(annotation):
				_err(line_no, "未知类型标注 '%s'（可用：%s）" % [annotation, ", ".join(TYPE_NAMES)])
				continue

		if not _is_identifier(key):
			_err(line_no, "非法键名 '%s'（只允许字母、数字、下划线、点、连字符）" % key)
			continue

		var full_key := _current_path_string(current_path, key)
		if current.has(key):
			var first_line: int = _key_lines.get(full_key, 0)
			_err(line_no, "重复键 '%s'（首次定义在第 %d 行）" % [key, first_line])
			continue

		var parsed := _parse_value(value_part, annotation, line_no)
		if not parsed.get("ok", false):
			continue

		current[key] = parsed["value"]
		_key_lines[full_key] = line_no


func _enter_section(line: String, line_no: int) -> Dictionary:
	var close := line.find("]")
	if close < 0:
		_err(line_no, "section 缺少 ']': %s" % line)
		return {"ok": false}
	var name := line.substr(1, close - 1).strip_edges()
	var rest := line.substr(close + 1).strip_edges()
	if not rest.is_empty():
		_err(line_no, "section 声明后有多余内容: %s" % rest)
	if name.is_empty():
		_err(line_no, "section 名为空")
		return {"ok": false}

	var parts := _split_section_name(name)
	var node: Dictionary = _sections
	var path := PackedStringArray()
	for part in parts:
		if not _is_identifier(part):
			_err(line_no, "非法 section 名 '%s'" % part)
			return {"ok": false}
		path.append(part)
		if not node.has(part):
			node[part] = {}
		elif typeof(node[part]) != TYPE_DICTIONARY:
			_err(line_no, "section '%s' 与已有的同名键冲突" % part)
			return {"ok": false}
		node = node[part]
	return {"ok": true, "dict": node, "path": path}


func _parse_value(text: String, annotation: String, line_no: int) -> Dictionary:
	if text.is_empty():
		_err(line_no, "缺少值（'=' 右侧为空）")
		return {"ok": false}

	# 数组
	if text.begins_with("{"):
		if not text.ends_with("}"):
			_err(line_no, "数组缺少 '}': %s" % text)
			return {"ok": false}
		if not annotation.is_empty():
			_err(line_no, "数组值不支持类型标注 '%s'" % annotation)
			return {"ok": false}
		var inner := text.substr(1, text.length() - 2).strip_edges()
		var out: Array = []
		if inner.is_empty():
			return {"ok": true, "value": out}
		for piece in _split_outside_quotes(inner, ","):
			var item := piece.strip_edges()
			if item.is_empty():
				_err(line_no, "数组中有空元素: %s" % text)
				return {"ok": false}
			var sub := _parse_value(item, "", line_no)
			if not sub.get("ok", false):
				return {"ok": false}
			out.append(sub["value"])
		return {"ok": true, "value": out}

	# 无标注 → 自动推断
	if annotation.is_empty():
		return {"ok": true, "value": _infer(text)}

	return _coerce(text, annotation, line_no)


func _infer(text: String) -> Variant:
	if _is_quoted(text):
		return _unquote(text)
	var low := text.to_lower()
	if TRUE_TOKENS.has(low):
		return true
	if FALSE_TOKENS.has(low):
		return false
	if text.is_valid_int():
		return text.to_int()
	if text.is_valid_float():
		return text.to_float()
	return text


func _coerce(text: String, annotation: String, line_no: int) -> Dictionary:
	# 标注按引号内文本强校验（color 的例子本身就是带引号的 "#FFB84D"）
	var token := _unquote(text)
	var low := token.to_lower()
	match annotation:
		"bool":
			if TRUE_TOKENS.has(low):
				return {"ok": true, "value": true}
			if FALSE_TOKENS.has(low):
				return {"ok": true, "value": false}
			_err(line_no, "类型标注 bool 不匹配: %s" % text)
			return {"ok": false}
		"int":
			if token.is_valid_int():
				return {"ok": true, "value": token.to_int()}
			_err(line_no, "类型标注 int 不匹配: %s" % text)
			return {"ok": false}
		"float":
			if token.is_valid_float():
				return {"ok": true, "value": token.to_float()}
			_err(line_no, "类型标注 float 不匹配: %s" % text)
			return {"ok": false}
		"string":
			return {"ok": true, "value": token}
		"color":
			if _is_hex_color(token):
				return {"ok": true, "value": Color.html(token)}
			_err(line_no, "类型标注 color 需要 \"#RRGGBB\" 或 \"#RRGGBBAA\": %s" % text)
			return {"ok": false}
		"vec3":
			var parts := _split_outside_quotes(token, ",")
			if parts.size() == 3:
				var nums := PackedFloat64Array()
				for part in parts:
					var piece := part.strip_edges()
					if not piece.is_valid_float():
						nums.clear()
						break
					nums.append(piece.to_float())
				if nums.size() == 3:
					return {"ok": true, "value": Vector3(nums[0], nums[1], nums[2])}
			_err(line_no, "类型标注 vec3 需要三个数字（如 1,2,3）: %s" % text)
			return {"ok": false}

	_err(line_no, "未处理的类型标注 '%s'" % annotation)
	return {"ok": false}


func _lookup(section_name: String) -> Dictionary:
	var parts := _split_section_name(section_name)
	if parts.is_empty():
		return {}
	var node: Variant = _sections
	for part in parts:
		if typeof(node) != TYPE_DICTIONARY:
			return {}
		var dict := node as Dictionary
		if not dict.has(part):
			return {}
		node = dict[part]
	if typeof(node) != TYPE_DICTIONARY:
		return {}
	return node


func _collect_sections(node: Dictionary, prefix: String, out: PackedStringArray) -> void:
	for key in node.keys():
		var value: Variant = node[key]
		if typeof(value) != TYPE_DICTIONARY:
			continue
		var full := str(key) if prefix.is_empty() else prefix + "." + str(key)
		out.append(full)
		_collect_sections(value, full, out)


func _split_section_name(name: String) -> PackedStringArray:
	var out := PackedStringArray()
	for part in name.split(".", false):
		var piece := part.strip_edges()
		if not piece.is_empty():
			out.append(piece)
	return out


func _current_path_string(path: PackedStringArray, key: String) -> String:
	var prefix := ".".join(path)
	return key if prefix.is_empty() else prefix + "." + key


func _strip_comment(line: String) -> String:
	var in_quote := false
	for i in line.length():
		var c := line[i]
		if c == "\"":
			in_quote = not in_quote
		elif not in_quote and (c == ";" or c == "#"):
			return line.substr(0, i)
	return line


func _split_outside_quotes(text: String, separator: String) -> PackedStringArray:
	var out := PackedStringArray()
	var buffer := ""
	var in_quote := false
	for i in text.length():
		var c := text[i]
		if c == "\"":
			in_quote = not in_quote
		if c == separator and not in_quote:
			out.append(buffer)
			buffer = ""
			continue
		buffer += c
	out.append(buffer)
	return out


static func _is_quoted(text: String) -> bool:
	return text.length() >= 2 and text.begins_with("\"") and text.ends_with("\"")


static func _unquote(text: String) -> String:
	var token := text.strip_edges()
	if _is_quoted(token):
		return token.substr(1, token.length() - 2)
	return token


static func _is_hex_color(text: String) -> bool:
	var token := text.strip_edges()
	if token.begins_with("#"):
		token = token.substr(1)
	if token.length() != 6 and token.length() != 8:
		return false
	for c in token:
		if not "0123456789abcdefABCDEF".contains(c):
			return false
	return true


static func _is_identifier(text: String) -> bool:
	if text.is_empty():
		return false
	if not _is_identifier_start(text[0]):
		return false
	for i in range(1, text.length()):
		if not _is_identifier_char(text[i]):
			return false
	return true


static func _is_identifier_start(c: String) -> bool:
	return (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "_"


static func _is_identifier_char(c: String) -> bool:
	return _is_identifier_start(c) or (c >= "0" and c <= "9") or c == "." or c == "-"


func _err(line_no: int, message: String) -> void:
	errors.append("%s:%d: %s" % [source, line_no, message])
