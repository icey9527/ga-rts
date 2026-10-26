class_name SelectionPanel
extends PanelContainer

## 右下单位详情面板（原版 ui/selection_panel.lua 的最小等价物）。
##
## 原版 340×150 固定在 `(W-358, H-180)`：
##   单选中 → 名字 / 机型|高度|状态 / 右上 42px 头像 / HP·EN·SP 三条粗条 / `HP x/y EN x/y DMG n`
##   多选中 → 「编队选择」+ 数量 + 合计 HP/EN 条
##
## 我们只做**有的数据**：HP、速度、高度、状态、当前目标。
## 原版的 EN（能量）与 SP（必杀条）还没有对应系统（技能卡才会引入），
## 所以刻意不画空条 —— 一条永远满/永远空的进度条比没有更误导。
##
## 面板是纯只读消费者：只读 GameState.selected_units() 与 Unit 的公有字段。

## 三条数值槽：HP / 速度 / 高度。每槽 = 标签 + 背景条 + 前景条
const BAR_WIDTH := 150.0
const BAR_HEIGHT := 8.0

var _session: BattleSession = null
var _title: Label = null
var _subtitle: Label = null
var _detail: Label = null
var _bars: Array[Dictionary] = []


func _ready() -> void:
	custom_minimum_size = Vector2(340.0, 150.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false

	var root := VBoxContainer.new()
	root.add_theme_constant_override(&"separation", 4)
	add_child(root)

	_title = Label.new()
	_title.add_theme_font_size_override(&"font_size", 16)
	root.add_child(_title)

	_subtitle = Label.new()
	_subtitle.add_theme_font_size_override(&"font_size", 12)
	root.add_child(_subtitle)

	# 三条数值条：label 在左，条在右
	for i in 3:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		var label := Label.new()
		label.add_theme_font_size_override(&"font_size", 11)
		label.custom_minimum_size = Vector2(28.0, 0.0)
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
		root.add_child(row)
		_bars.append({"label": label, "bar": bar})

	_detail = Label.new()
	_detail.add_theme_font_size_override(&"font_size", 11)
	root.add_child(_detail)


func bind_session(session: BattleSession) -> void:
	_session = session


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	var units := _selected_units()
	if units.is_empty():
		visible = false
		return
	visible = true

	if units.size() == 1:
		_show_single(units[0])
	else:
		_show_group(units)


func _show_single(unit: Unit) -> void:
	_title.text = unit.def_id
	var state_name := UnitStates.state_name(unit.state)
	_subtitle.text = "高度 %+.0f m   |   %s" % [unit.position.y, state_name]

	_set_bar(0, "HP", unit.hp_ratio(), _hp_color(unit.hp_ratio()),
		"%d/%d" % [roundi(unit.hp), roundi(unit.max_hp)])
	# 速度条按本机型自己的上限归一，否则快慢无法横向比较
	var speed_ratio := 0.0
	if unit.max_speed > 0.0:
		speed_ratio = clampf(unit.speed / unit.max_speed, 0.0, 1.0)
	_set_bar(1, "速度", speed_ratio, Color(0.35, 0.75, 1.0),
		"%.0f/%.0f" % [unit.speed, unit.max_speed])
	# 高度条：以层容差带 ±150 m 为满格（ADR-0003），当前层内偏移即比例
	var alt_ratio := clampf((unit.position.y + 150.0) / 300.0, 0.0, 1.0)
	_set_bar(2, "高度", alt_ratio, Color(0.85, 0.75, 0.35),
		"%+.0f m" % unit.position.y)

	var target_text := "无"
	if unit.target_id >= 0:
		target_text = "#%d" % unit.target_id
	_detail.text = "目标 %s   行为 %s" % [target_text, String(unit.behavior_kind)]


func _show_group(units: Array[Unit]) -> void:
	_title.text = "编队选择"
	_subtitle.text = "%d 艘" % units.size()
	var hp_sum := 0.0
	var hp_max := 0.0
	for unit in units:
		hp_sum += unit.hp
		hp_max += unit.max_hp
	var ratio := 0.0 if hp_max <= 0.0 else clampf(hp_sum / hp_max, 0.0, 1.0)
	_set_bar(0, "HP", ratio, _hp_color(ratio),
		"%d/%d" % [roundi(hp_sum), roundi(hp_max)])
	# 多选时速度/高度没有单一含义，留空而不是画个假的平均值
	_set_bar(1, "速度", 0.0, Color(0.3, 0.3, 0.34), "-")
	_set_bar(2, "高度", 0.0, Color(0.3, 0.3, 0.34), "-")
	_detail.text = "多选时只统计合计血量"


func _set_bar(index: int, label: String, ratio: float, color: Color, text: String) -> void:
	if index < 0 or index >= _bars.size():
		return
	var entry: Dictionary = _bars[index]
	# 标签只放短名（HP/速度/高度）；具体数值走 tooltip。
	# 面板宽 340px，三条都要带数字会把条子挤到看不清。
	(entry["label"] as Label).text = label
	(entry["label"] as Label).tooltip_text = text
	var bar := entry["bar"] as ColorRect
	bar.custom_minimum_size = Vector2(maxf(BAR_WIDTH * clampf(ratio, 0.0, 1.0), 0.0), BAR_HEIGHT)
	bar.color = color
	bar.tooltip_text = text


## 验证用：面板当前是否在显示
func is_showing() -> bool:
	return visible


## 验证用：标题行文本
func title_text() -> String:
	return "" if _title == null else _title.text


## 验证用：副标题文本（高度 / 状态）
func subtitle_text() -> String:
	return "" if _subtitle == null else _subtitle.text


## 验证用：底部明细文本
func detail_text() -> String:
	return "" if _detail == null else _detail.text


func _selected_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for item in GameState.selected_units():
		if item is Unit and (item as Unit).alive:
			out.append(item)
	return out


func _hp_color(ratio: float) -> Color:
	if ratio > 0.5:
		return Color(0.35, 0.95, 0.45)
	if ratio > 0.25:
		return Color(1.0, 0.85, 0.25)
	return Color(1.0, 0.3, 0.25)
