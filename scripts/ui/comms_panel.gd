class_name CommsPanel
extends Control

## 右侧通讯播报列（原版 ui/comms.lua 的最小等价物）。
##
## 原版：右上 `x = W-w-18, w = min(342, W-290)`，起始 `y=48`，
## 最多 3 条气泡，每条 = 头像 + 九宫格文本框 + 逐字打字机文本。
## 那是**战场所有反馈的统一出口**：受击、失能、命令失误、剧情、敌方嘲讽。
##
## 我们现在只有 unit_died 一个数据源（剧情/对白系统属 S5 后续），
## 但结构按原版做：多条气泡、头像、打字机、自动淡出。
## 以后接对白/受击播报只需要调 post()，不用改绘制。
##
## 本类是纯表现：不碰模拟层，只读会话信号与 PortraitCache。

## 最多同时显示几条（原版 3 条）
const MAX_BUBBLES := 3
## 气泡尺寸与间距
const BUBBLE_WIDTH := 320.0
const BUBBLE_HEIGHT := 58.0
const BUBBLE_GAP := 6.0
const TOP_MARGIN := 48.0
const SIDE_MARGIN := 18.0
## 头像边长（原版 64；我们气泡较矮，取 44）
const PORTRAIT_SIZE := 44.0
## 打字机速度（字符/秒）。原版是逐字出现的手感，太快就失去"通讯"的味道。
const CHARS_PER_SECOND := 45.0
## 完全显示后停留多久开始淡出（秒）
const HOLD_SECONDS := 4.5
## 淡出时长（秒）
const FADE_SECONDS := 0.8
## 文本字号
const TEXT_SIZE := 12
const LINE_HEIGHT := 15.0
## 气泡底色与描边
const BG_COLOR := Color(0.05, 0.07, 0.09, 0.86)
const TEXT_COLOR := Color(0.92, 0.95, 1.0, 0.95)

## 单条气泡：{"text", "chara", "team", "age"}
var _bubbles: Array[Dictionary] = []
var _session: BattleSession = null


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true


func bind_session(session: BattleSession) -> void:
	_unbind_session()
	_session = session
	if session == null:
		return
	# 鸭子类型：会话可能被换成只声明了 units() 的测试替身
	if session.has_signal(&"unit_died"):
		var handler := Callable(self, &"_on_unit_died")
		if not session.is_connected(&"unit_died", handler):
			session.connect(&"unit_died", handler)


## 发一条播报。以后接对白/受击反馈都从这里进，绘制不用动。
## chara 传角色编号用于头像；空则只画文字。
func post(text: String, chara: String = "", team: int = 0) -> void:
	if text.strip_edges().is_empty():
		return
	_bubbles.append({"text": text, "chara": chara, "team": team, "age": 0.0})
	# 超量时丢最旧的：通讯列只保留"刚刚发生了什么"
	while _bubbles.size() > MAX_BUBBLES:
		_bubbles.pop_front()
	queue_redraw()


func _process(delta: float) -> void:
	if _bubbles.is_empty():
		return
	var alive: Array[Dictionary] = []
	for bubble in _bubbles:
		bubble["age"] = float(bubble.get("age", 0.0)) + delta
		var revealed := _reveal_seconds(String(bubble["text"]))
		if float(bubble["age"]) > revealed + HOLD_SECONDS + FADE_SECONDS:
			continue
		alive.append(bubble)
	_bubbles = alive
	queue_redraw()


func _draw() -> void:
	if _bubbles.is_empty():
		return
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var view := get_viewport_rect().size
	var x := view.x - BUBBLE_WIDTH - SIDE_MARGIN
	var y := TOP_MARGIN
	for bubble in _bubbles:
		var alpha := _alpha_of(bubble)
		var team := int(bubble.get("team", 0))
		# 圆角底板 + 队伍色边框：用 draw_rect 叠两层做出"框"的效果，
		# 不引入九宫格贴图 —— 原版那套 slg_tbox 素材没迁，画一个干净的框更实在。
		var rect := Rect2(x, y, BUBBLE_WIDTH, BUBBLE_HEIGHT)
		draw_rect(rect, Color(BG_COLOR.r, BG_COLOR.g, BG_COLOR.b, BG_COLOR.a * alpha))
		var border := _team_color(team)
		border.a *= alpha
		draw_rect(rect, border, false, 2.0)

		# 头像
		var face := PortraitCache.texture(String(bubble.get("chara", "")))
		var face_rect := Rect2(
			Vector2(x + 6.0, y + (BUBBLE_HEIGHT - PORTRAIT_SIZE) * 0.5),
			Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE))
		if face != null:
			draw_texture_rect(face, face_rect, false)
		else:
			draw_rect(face_rect, Color(0.15, 0.18, 0.22, alpha))

		# 打字机文本
		var shown := _revealed_text(bubble)
		var text_x := face_rect.end.x + 10.0
		var text_y := y + 18.0
		var text_color := TEXT_COLOR
		text_color.a *= alpha
		# 两行显示：气泡只有 58px 高，长句靠这里换行（没有自动换行就截断）
		var remaining := shown
		var lines := 0
		while not remaining.is_empty() and lines < 2:
			var chunk := remaining
			if font.get_string_size(chunk, HORIZONTAL_ALIGNMENT_LEFT, -1.0, TEXT_SIZE).x > BUBBLE_WIDTH - PORTRAIT_SIZE - 30.0:
				# 按字符二分找能放下的最长前缀
				var lo := 0
				var hi := chunk.length()
				while lo < hi:
					var mid := (lo + hi + 1) / 2
					var probe := chunk.substr(0, mid)
					if font.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1.0, TEXT_SIZE).x <= BUBBLE_WIDTH - PORTRAIT_SIZE - 30.0:
						lo = mid
					else:
						hi = mid - 1
				chunk = chunk.substr(0, maxi(lo, 1))
			draw_string(font, Vector2(text_x, text_y), chunk,
				HORIZONTAL_ALIGNMENT_LEFT, -1.0, TEXT_SIZE, text_color)
			remaining = remaining.substr(chunk.length())
			text_y += LINE_HEIGHT
			lines += 1

		y += BUBBLE_HEIGHT + BUBBLE_GAP


## 当前气泡数（验证用）
func bubble_count() -> int:
	return _bubbles.size()


## 第 index 条气泡的完整文本（验证用，不受打字机影响）
func bubble_text(index: int) -> String:
	if index < 0 or index >= _bubbles.size():
		return ""
	return String(_bubbles[index].get("text", ""))


## 第 index 条气泡当前已显示的字数（验证用：确认打字机在推进）
func revealed_length(index: int) -> int:
	if index < 0 or index >= _bubbles.size():
		return 0
	return _revealed_text(_bubbles[index]).length()


## 手动推进时间（验证用：避免依赖引擎帧率）
func advance(delta: float) -> void:
	_process(delta)


func _on_unit_died(unit: Unit, killer_id: int) -> void:
	if unit == null:
		return
	var text := "%s #%d 战损" % [unit.def_id, unit.id]
	if killer_id >= 0:
		text += "（击毁者 #%d）" % killer_id
	post(text, unit.portrait_chara, unit.team)


func _reveal_seconds(text: String) -> float:
	return float(text.length()) / maxf(CHARS_PER_SECOND, 1.0)


func _revealed_text(bubble: Dictionary) -> String:
	var text := String(bubble.get("text", ""))
	var count := int(float(bubble.get("age", 0.0)) * CHARS_PER_SECOND)
	return text.substr(0, clampi(count, 0, text.length()))


## 淡出透明度。前 HOLD 秒全亮，之后线性淡出。
func _alpha_of(bubble: Dictionary) -> float:
	var age := float(bubble.get("age", 0.0))
	var revealed := _reveal_seconds(String(bubble.get("text", "")))
	var hold_end := revealed + HOLD_SECONDS
	if age <= hold_end:
		return 1.0
	return clampf(1.0 - (age - hold_end) / FADE_SECONDS, 0.0, 1.0)


func _team_color(team: int) -> Color:
	# 与 HUD 徽章同口径：0 青、1 橙红
	return Color(0.3, 1.0, 0.8) if team == 0 else Color(1.0, 0.55, 0.35)


func _unbind_session() -> void:
	var old := _session
	_session = null
	if old == null:
		return
	if old.has_signal(&"unit_died"):
		var handler := Callable(self, &"_on_unit_died")
		if old.is_connected(&"unit_died", handler):
			old.disconnect(&"unit_died", handler)
