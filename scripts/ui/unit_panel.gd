class_name UnitPanel
extends PanelContainer

## 选中单位面板（旧版 `unit_panel` 的最小等价物）。
##
## 旧版 Tab 打开它，列出当前选中的船：机型、血量、状态。
## 我们之前完全没有这个面板 —— 玩家只能靠血条猜自己在指挥什么。
##
## 键位说明：旧版用 Tab，而我们的 Tab 已经是 2D/3D 视图切换（ADR-0001 的核心操作），
## 所以面板改用 **U**。差异记在 docs/controls-audit.md，不偷偷占用 Tab。
##
## 为什么读 GameState.selected_units() 而不是让 InputRouter 推：
##   选中状态本来就是全局可读的（HUD 已经在读），再插一条推送链路只会多一个
##   "面板里的选中列表和别处不一致"的隐患。面板是纯只读消费者。

## 最多显示多少行（选太多时只显示前 N 个，避免面板撑满屏幕）
const MAX_ROWS := 10
## 血条宽度（像素）
const BAR_WIDTH := 96.0
const BAR_HEIGHT := 6.0

var _session: BattleSession = null
## 已建好的行控件：{ label: Label, bar: ColorRect, bar_bg: ColorRect }
var _rows: Array[Dictionary] = []
var _root: VBoxContainer = null
## 面板是否展开（由 toggle 控制）
var _expanded := false


func _ready() -> void:
	# 面板默认收起，按 U 才展开
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(260.0, 0.0)

	_root = VBoxContainer.new()
	_root.add_theme_constant_override(&"separation", 2)
	add_child(_root)

	var title := Label.new()
	title.text = "选中单位（U 关闭）"
	title.add_theme_font_size_override(&"font_size", 12)
	_root.add_child(title)

	for i in MAX_ROWS:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 6)

		var label := Label.new()
		label.add_theme_font_size_override(&"font_size", 12)
		label.custom_minimum_size = Vector2(140.0, 0.0)
		row.add_child(label)

		var bar_bg := ColorRect.new()
		bar_bg.color = Color(0.1, 0.1, 0.12, 0.9)
		bar_bg.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		bar_bg.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar_bg)

		var bar := ColorRect.new()
		bar.color = Color(0.35, 0.95, 0.45)
		bar.custom_minimum_size = Vector2(BAR_WIDTH, BAR_HEIGHT)
		bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(bar)

		_root.add_child(row)
		_rows.append({"row": row, "label": label, "bar": bar})
		row.visible = false


func bind_session(session: BattleSession) -> void:
	_session = session


## 展开 / 收起（U 键）
func toggle() -> void:
	_expanded = not _expanded
	visible = _expanded
	if _expanded:
		_refresh()


func is_expanded() -> bool:
	return _expanded


## 当前显示的行数（验证用）
func row_count() -> int:
	var n := 0
	for entry in _rows:
		if (entry["row"] as HBoxContainer).visible:
			n += 1
	return n


## 第 index 行的文本（验证用）
func row_text(index: int) -> String:
	if index < 0 or index >= _rows.size():
		return ""
	return (_rows[index]["label"] as Label).text


func _process(_delta: float) -> void:
	# 收起时不刷新：面板是只读展示，没必要每帧算
	if _expanded:
		_refresh()


func _refresh() -> void:
	var units := _visible_units()
	for i in _rows.size():
		var entry: Dictionary = _rows[i]
		var row := entry["row"] as HBoxContainer
		if i >= units.size():
			row.visible = false
			continue
		var unit: Unit = units[i]
		row.visible = true
		(entry["label"] as Label).text = "%s  %d%%" % [
			unit.def_id, int(round(unit.hp_ratio() * 100.0))]
		var bar := entry["bar"] as ColorRect
		var ratio := clampf(unit.hp_ratio(), 0.0, 1.0)
		bar.custom_minimum_size = Vector2(maxf(BAR_WIDTH * ratio, 0.0), BAR_HEIGHT)
		bar.color = _hp_color(ratio)


## 当前应该显示哪些单位：优先选中列表，没有选中就显示全场己方单位。
## 旧版面板就是"选中列表"；没选中时显示己方全体更有用（能看出舰队总量）。
func _visible_units() -> Array[Unit]:
	var out: Array[Unit] = []
	var selected := GameState.selected_units()
	for item in selected:
		if item is Unit and (item as Unit).alive:
			out.append(item)
	if not out.is_empty():
		return _truncate(out)
	if _session == null:
		return out
	for unit in _session.units():
		if unit.alive:
			out.append(unit)
	return _truncate(out)


func _truncate(units: Array[Unit]) -> Array[Unit]:
	if units.size() <= MAX_ROWS:
		return units
	var out: Array[Unit] = []
	for i in MAX_ROWS:
		out.append(units[i])
	return out


func _hp_color(ratio: float) -> Color:
	if ratio > 0.5:
		return Color(0.35, 0.95, 0.45)
	if ratio > 0.25:
		return Color(1.0, 0.85, 0.25)
	return Color(1.0, 0.3, 0.25)
