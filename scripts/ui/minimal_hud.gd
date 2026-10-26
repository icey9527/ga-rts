class_name MinimalHUD
extends Control

## 最小 HUD（L3 交互层）。**只读** L1 模拟层，不缓存任何模拟真值。
##
## 存在的唯一理由：现在框选之后看不出选中了谁、也不知道谁快被打死了。
## 所以这里只画三样东西，一个都不多做：
##   1. 单位标记（队伍色圆点）—— 回答"谁在哪"
##   2. 血条 —— 回答"谁快没了"
##   3. 选中圆环 —— 回答"我刚才框到了谁"
## 外加一行汇总与战损播报（unit_died 的唯一用途）。
## L4 补充：顶部状态条（关卡/时间/双方存活/分数）与底部操作提示 ——
## 这两块不读模拟真值以外的东西，也不参与任何交互，纯"让玩家知道现在几点了、还剩谁"。
##
## 硬规则 4（表现层只读）：本文件里对 Unit 的访问只有 `position` / `team` /
## `id` / `def_id` / `hp_ratio()`，没有任何一处赋值。想"看起来改一下"的东西一律不在这里做。
##
## 为什么不沿用 ViewProjection：它要求注入一台相机 + 参考平面，而 HUD 只是把世界点
## 投到屏幕上（单向、无参考平面、无拾取）。为了三个 draw_* 去接一层注入，
## 反而会让 HUD 必须等装配器先跑起来。等 2D/3D 双视图真的需要 HUD 一起切换时再收编。
##
## 为什么每帧重绘而不是攒事件：模拟侧每 tick 都在动，屏幕坐标没有"没变"的时候。
## 缓存一份快照就得处理"哪些变了要失效"，那是一整类 bug；queue_redraw() 是最便宜的正确答案。

## 单位标记半径（像素）。太小点不住，太大会糊住下面真实模型
const MARKER_RADIUS := 5.0

## 头顶徽章（原版 tactical_markers 的等价物）。
## 原版画的是 32 px 圆形**角色立绘**；那批立绘资源（content/teams/*/chara/*/face/）
## 在 S0.5 根本没迁，所以这里用“队色圆底 + 机型缩写”当占位 ——
## 目的不是好看，而是让玩家在混战里能一眼分清“这条是谁”。
const BADGE_RADIUS := 11.0
const BADGE_FONT_SIZE := 9
## 徽章中心高于机体屏幕位置多少像素。与点选共用同一个常量（单一口径）
## —— 两边各写一个数就会出现“看得到徽章但点不中”的偏差。
const BADGE_OFFSET := ViewProjection.MARKER_OFFSET_PX
## 选中圆环半径（像素）。必须明显大于标记半径，否则两个圆重叠成一块
const SELECT_RING_RADIUS := 9.0
const SELECT_RING_POINTS := 24
const SELECT_RING_WIDTH := 2.0
## 血条尺寸（像素）。24×3 是"能看出比例、又不至于盖住舰体"的平衡点
const HP_BAR_WIDTH := 24.0
const HP_BAR_HEIGHT := 3.0
## 血条底边到标记中心的距离（像素）
const HP_BAR_GAP := 10.0
## 血量阈值：以上绿、中间黄、以下红
const HP_WARN_RATIO := 0.5
const HP_CRITICAL_RATIO := 0.25
## 血量百分比文字只在掉到这个比例以下才显示（满血也写字会糊成一团）
const HP_LABEL_RATIO := 0.75
const LABEL_FONT_SIZE := 12
const SUMMARY_MARGIN := 8.0
## 战损提示的存活时间（秒）
const TOAST_DURATION := 3.0
## 提示最多保留几条。战场上可能成批阵亡，无上限就会把左侧刷满
const MAX_NOTICES := 6
## 屏幕外这个像素范围内仍然照画（只是省掉完全不可能看到的点）
const CULL_MARGIN := 64.0

## 顶部状态条高度（像素）：13 号字 + 上下留白，一行信息不挤。
#  用半透明而不是实心黑：全黑条会把战场上缘遮死，玩家看不到从上方压过来的敌人
const TOP_BAR_HEIGHT := 32.0
const TOP_BAR_COLOR := Color(0, 0, 0, 0.55)
const TOP_BAR_FONT_SIZE := 13
## 文字基线。不用垂直居中 API：draw_string 的基线语义最稳，写死一个数与 32px 高对齐
const TOP_BAR_TEXT_Y := 21.0
const TOP_BAR_TEXT_COLOR := Color(0.85, 0.9, 1.0, 0.95)
## 各列固定 x 偏移。故意做成定宽列：时间/人数每帧都在变，
## 改成按字宽动态排版会让整行来回抖动，读数反而更难盯
const TOP_BAR_COLUMNS: Array[float] = [12.0, 140.0, 268.0, 368.0, 468.0]
## 击毁一单位记多少分。纯表现计分口径（不是模拟真值），将来要改经济系统也不必动这里
const SCORE_PER_KILL := 100
## 底部操作提示
const HINT_TEXT := "左键: 选择 / 框选 | 右键: 命令菜单 | U: 单位面板 | 空格: 暂停 | F: 跟随 | Tab: 2D/3D"
const HINT_FONT_SIZE := 12
const HINT_COLOR := Color(0.7, 0.75, 0.8, 0.85)
const HINT_LEFT_MARGIN := 12.0
const HINT_BOTTOM_MARGIN := 8.0
## 暂停提示：字号更大、金色，压在提示行上方且居中 —— 暂停时玩家最该知道的就是这件事
const PAUSE_TEXT := "游戏已暂停（空格继续）"
const PAUSE_FONT_SIZE := 16
const PAUSE_COLOR := Color(1, 0.85, 0.3, 1)
## 暂停行基线距提示行基线的距离（像素）
const PAUSE_LINE_GAP := 22.0
## 左上角汇总 / 播报的起画 y。必须让到状态条下方：
## 两者都贴左上角，不让就会让"关卡/时间"和"单位 N"叠成一行看不清的乱码。
## 改的是偏移量而不是汇总内容 —— 读数口径一个字没动
const SUMMARY_TOP := SUMMARY_MARGIN + TOP_BAR_HEIGHT

## team 0 =  PLAYER（青），team 1 = 敌方（橙红）。颜色写死在这里，
## 因为队伍配色属于"玩家一眼要分得清"的表现决策，不该散到数据表里
const TEAM_COLORS: Array[Color] = [Color(0.3, 1.0, 0.8), Color(1.0, 0.45, 0.3)]
## 超过 2 队（剧本 / 验证场景）时的兜底色，而不是复用 0/1 队色号造成误读
const TEAM_FALLBACK_COLOR := Color(0.85, 0.85, 0.95)
const HP_BAR_BACKGROUND := Color(0.09, 0.09, 0.11, 0.85)
const HP_HEALTHY_COLOR := Color(0.35, 0.95, 0.45)
const HP_WARN_COLOR := Color(1.0, 0.85, 0.25)
const HP_CRITICAL_COLOR := Color(1.0, 0.3, 0.25)
const SELECT_COLOR := Color(1.0, 1.0, 1.0, 0.9)
const SUMMARY_COLOR := Color(0.85, 0.9, 1.0, 0.95)
const TOAST_COLOR := Color(1.0, 0.55, 0.45, 1.0)

## 要显示的战斗会话。null = 未接线（不是错误状态）：
## 此时单位标记/血条/汇总全不画，但顶部状态条与底部提示照画
var _session: BattleSession = null
## 战损播报（元素 = {"text": String, "left": float}）。纯表现数据，不进模拟层
var _notices: Array[Dictionary] = []


## 接线入口：由外部（battle.gd / 场景装配）调用。
## 传 null 等价于解绑 —— 换关卡时先给 null 再给新会话，比"记得自己断开"可靠。
func bind_session(session: BattleSession) -> void:
	_unbind_session()
	_session = session
	if session == null:
		return
	# 鸭子类型而不是直接 session.unit_died.connect()：
	# 会话可能被换成测试替身（只声明了 units()），没有信号也不该报错
	if session.has_signal(&"unit_died"):
		var handler := Callable(self, &"_on_unit_died")
		if not session.is_connected(&"unit_died", handler):
			session.connect(&"unit_died", handler)


## 当前绑定的会话（诊断 / 验证用；会返回 null，调用方要自己判）
func session() -> BattleSession:
	return _session


## 当前战损播报条数（验证用：确认信号真的接上了）
func notice_count() -> int:
	return _notices.size()


func _process(delta: float) -> void:
	_advance_notices(delta)
	# 模拟每帧都在推进，屏幕坐标因此每帧都不同；无条件重绘比维护失效标记便宜
	queue_redraw()


func _draw() -> void:
	# 顶部状态条 / 底部提示最先画：它们不依赖 session 也不依赖相机。
	# 放最前面的唯一理由就是下面那几个 return —— 没接线 / 相机未装配 / 场上没人时
	# 后面会提前退出，而这两块不能跟着消失（显示"友军: -"总比整块 HUD 变空白好排查）。
	# 代价是单位标记会盖在状态条上方一点点，那点重叠比"HUD 一半不显示"划算。
	_draw_top_status_bar()
	_draw_bottom_hints()

	var session := _session
	if session == null:
		return
	var camera := _current_camera()
	if camera == null:
		return
	var units := session.units()
	if units.is_empty():
		return

	var font := ThemeDB.fallback_font
	# 视野外的点不画：既省 draw 调用，也避开 unproject 在视口外给出的巨大坐标
	var view_rect := get_viewport_rect().grow(CULL_MARGIN)
	var selected := _selected_unit_ids()
	var team_counts := {}
	var drawn := 0

	for unit in units:
		if unit == null:
			continue
		var world := unit.position
		# unproject_position 返回的是 Vector2，没有 z 可以判"是否在相机背面"，
		# 所以这里用 camera.is_position_behind()。背面点若照画，会得到一个左右镜像的
		# 幽灵标记（相机身后的东西投影到屏幕正对面），玩家会以为那里真有一艘船。
		if camera.is_position_behind(world):
			continue
		var screen := camera.unproject_position(world)
		if not view_rect.has_point(screen):
			continue

		team_counts[unit.team] = int(team_counts.get(unit.team, 0)) + 1
		drawn += 1

		# 画序：选中光环 → 倒三角 → 血条 → 徽章。
		# 徽章最后画，保证它是队色与机型缩写的视觉锚点，不会被血条或三角盖住。
		if selected.has(unit.id):
			draw_arc(screen, SELECT_RING_RADIUS, 0.0, TAU,
				SELECT_RING_POINTS, SELECT_COLOR, SELECT_RING_WIDTH, true)
		var badge_at := screen - Vector2(0.0, BADGE_OFFSET)
		_draw_marker_triangle(badge_at, screen, unit)
		_draw_health_bar(badge_at, unit, font)
		_draw_marker_badge(badge_at, unit, font, selected.has(unit.id))

	_draw_summary(units.size(), drawn, team_counts, selected.size(), font)


# ---------------------------------------------------------------- 单单位绘制


## 血条：背景恒画（给出"这里有多长"的基准），前景按血量比例裁宽。
## 不画满就补一条底色，否则低血量时分不清"血条短"和"没有血条"。
## at 是**徽章中心**：血条画在徽章上方，不挡机型缩写。
func _draw_health_bar(at: Vector2, unit: Unit, font: Font) -> void:
	var ratio := clampf(unit.hp_ratio(), 0.0, 1.0)
	var bar_rect := Rect2(
		Vector2(at.x - HP_BAR_WIDTH * 0.5, at.y - BADGE_RADIUS - HP_BAR_GAP),
		Vector2(HP_BAR_WIDTH, HP_BAR_HEIGHT))
	draw_rect(bar_rect, HP_BAR_BACKGROUND)
	if ratio > 0.0:
		var fill := bar_rect
		fill.size.x = HP_BAR_WIDTH * ratio
		draw_rect(fill, _hp_color(ratio))

	# 数字只在受伤之后出现：满编的战场本来就挤，多一行字只是噪声
	if ratio < HP_LABEL_RATIO:
		draw_string(font,
			Vector2(bar_rect.position.x, bar_rect.position.y - 2.0),
			"%d%%" % roundi(ratio * 100.0),
			HORIZONTAL_ALIGNMENT_LEFT, HP_BAR_WIDTH, LABEL_FONT_SIZE,
			_hp_color(ratio))


## 头顶徽章：深色外圈 + 队色内圆 + 机型缩写。
## 选中时描边变白，与脚下的选中光环双重确认（远处光环可能被船体挡住）。
func _draw_marker_badge(at: Vector2, unit: Unit, font: Font, is_selected: bool) -> void:
	draw_circle(at, BADGE_RADIUS + 2.0, Color(0.04, 0.05, 0.07, 0.9))
	draw_circle(at, BADGE_RADIUS, _team_color(unit.team).darkened(0.45))
	var ring := SELECT_COLOR if is_selected else _team_color(unit.team)
	draw_arc(at, BADGE_RADIUS, 0.0, TAU, 24, ring, 2.0, true)
	var label := _marker_label(unit)
	if label.is_empty() or font == null:
		return
	var label_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BADGE_FONT_SIZE)
	draw_string(font,
		at + Vector2(-label_size.x * 0.5, label_size.y * 0.34),
		label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, BADGE_FONT_SIZE,
		Color(1.0, 1.0, 1.0, 0.92))


## 倒三角：从徽章底部指向机体，坐实“这个头标属于下面那艘船”。
## 徽章与机体距离不够时（船很大/缩得很近）就不画，避免三角被压成一个点、反而脏。
func _draw_marker_triangle(at: Vector2, body_screen: Vector2, unit: Unit) -> void:
	var top := at.y + BADGE_RADIUS + 1.0
	var bottom := body_screen.y - MARKER_RADIUS - 2.0
	if bottom - top < 6.0:
		return
	var mid := top + (bottom - top) * 0.55
	draw_colored_polygon(PackedVector2Array([
		Vector2(at.x, bottom),
		Vector2(at.x - 4.0, mid),
		Vector2(at.x + 4.0, mid),
	]), _team_color(unit.team))


## 徽章里的机型缩写。取 def_id 前 3 位大写（ou05 → OU0、fighter → FIG）。
## 不做完整 ID：徽章只有 22 px 宽，写全就成噪点了。
func _marker_label(unit: Unit) -> String:
	var id := unit.def_id
	if id.is_empty():
		return ""
	return id.substr(0, 3).to_upper()


## 左上角汇总 + 战损播报。
## 用文字而不是只靠颜色：颜色分不出"总共几艘、活了几艘"，而这些数字决定下一步怎么打。
func _draw_summary(total: int, visible: int, team_counts: Dictionary, selected: int, font: Font) -> void:
	var team_keys := team_counts.keys()
	team_keys.sort()
	var parts := PackedStringArray()
	for key in team_keys:
		parts.append("%d 队 %d" % [int(key), int(team_counts[key])])

	var line := "单位 %d（视野内 %d）  选中 %d" % [total, visible, selected]
	if not parts.is_empty():
		line += "  |  " + " / ".join(parts)
	draw_string(font, Vector2(SUMMARY_MARGIN, SUMMARY_TOP + LABEL_FONT_SIZE), line,
		HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, SUMMARY_COLOR)

	# 战损播报：unit_died 是它唯一的来源。故意不做队列动画，
	# 只让 alpha 随剩余时间淡出 —— 一眼能看出"刚没的是谁"就够了
	var y := SUMMARY_TOP + LABEL_FONT_SIZE * 2.0
	for notice in _notices:
		var alpha := clampf(float(notice.get("left", 0.0)) / TOAST_DURATION, 0.0, 1.0)
		var color := TOAST_COLOR
		color.a = alpha
		draw_string(font, Vector2(SUMMARY_MARGIN, y), String(notice.get("text", "")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, color)
		y += LABEL_FONT_SIZE + 2.0


# ---------------------------------------------------------------- 顶部状态条


## 顶部状态条：关卡 / 时间 / 双方存活数 / 分数。
## 这几项都是"每帧看一眼就知道局势"的量，之前只在左上角汇总里有个总数，
## 分不清哪一方快被打空 —— 旧版 Love2D 的 HUD 就是靠这条读战局的。
func _draw_top_status_bar() -> void:
	var font := ThemeDB.fallback_font
	var view_width := get_viewport_rect().size.x
	# 半透明黑条打底：文字直接压在战场上有时候完全看不清（尤其白蓝两队混战处）
	draw_rect(Rect2(Vector2.ZERO, Vector2(view_width, TOP_BAR_HEIGHT)), TOP_BAR_COLOR)

	var columns := _top_bar_texts()
	# 列数与文案数取小：将来少写一列也不会越界读，多写也不会错位
	for i in mini(columns.size(), TOP_BAR_COLUMNS.size()):
		draw_string(font, Vector2(TOP_BAR_COLUMNS[i], TOP_BAR_TEXT_Y), columns[i],
			HORIZONTAL_ALIGNMENT_LEFT, -1, TOP_BAR_FONT_SIZE, TOP_BAR_TEXT_COLOR)


## 状态条各列文案。单独抽出来是为了让排版（_draw_top_status_bar）与取值两张皮，
## 以后要验证"分数真的跟着击毁数涨"可以直接对这一堆字符串下断言
func _top_bar_texts() -> PackedStringArray:
	return PackedStringArray([
		"关卡: 遭遇战",
		"时间: %.1f" % _elapsed_seconds(),
		"友军: %s" % _alive_text(0),
		"敌军: %s" % _alive_text(1),
		"分数: %d" % _score(),
	])


## 已进行的秒数。只从模拟时钟读，绝不用 delta 自己累加：
## HUD 自己攒一份就会和暂停 / 掉帧补跑 / 回放对不上，显示的时间比战斗进程快或慢
func _elapsed_seconds() -> float:
	# 除 TICK_RATE 而不是写 60：频率将来改了（比如改 30Hz）这里自动跟上
	return float(Simulation.tick_index()) / float(Simulation.TICK_RATE)


## 某队存活数文案。session 没接线时给 "-" 而不是 0：
## 0 会被读成"友军全军覆没"，那是个完全不同的（且吓人的）信息
func _alive_text(team: int) -> String:
	var session := _session
	if session == null or not session.has_method(&"alive_count"):
		return "-"
	return str(session.alive_count(team))


## 分数：累计击毁数 × 100。击毁数取会话里已结算的死亡数，
## 不自己数 unit_died 信号 —— 信号可能因换关卡 / 重连丢失，而 session 的计数是权威值
func _score() -> int:
	var session := _session
	if session == null or not session.has_method(&"stats"):
		return 0
	var snapshot: Dictionary = session.stats()
	return int(snapshot.get("deaths_settled", 0)) * SCORE_PER_KILL


# ---------------------------------------------------------------- 底部提示


## 左下角操作提示 + （暂停时）居中的暂停横幅。
## 这些按键在代码里都实现了，但之前没有任何地方告诉玩家 —— 不写出来等于没实现。
func _draw_bottom_hints() -> void:
	var font := ThemeDB.fallback_font
	var view_size := get_viewport_rect().size
	# 从视口高度往上量：Control 若被装进别的容器导致 size 变小，提示也不会飘到屏幕中间
	var baseline := view_size.y - HINT_BOTTOM_MARGIN

	draw_string(font, Vector2(HINT_LEFT_MARGIN, baseline), HINT_TEXT,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HINT_FONT_SIZE, HINT_COLOR)

	# 暂停提示放在提示行上方而不是盖住它：暂停时玩家往往正想读那一行按键
	if Simulation.paused:
		draw_string(font, Vector2(0.0, baseline - PAUSE_LINE_GAP), PAUSE_TEXT,
			HORIZONTAL_ALIGNMENT_CENTER, view_size.x, PAUSE_FONT_SIZE, PAUSE_COLOR)


# ---------------------------------------------------------------- 数据读取


## 队伍色。未知队伍给中性色而不是复用 0/1 队色：
## 验证场景里 3 队同屏时，误用青色会让人以为它们是自己人
func _team_color(team: int) -> Color:
	if team >= 0 and team < TEAM_COLORS.size():
		return TEAM_COLORS[team]
	return TEAM_FALLBACK_COLOR


## 血量 → 颜色。三档硬阈值而不是连续渐变：渐变在 30% 和 40% 之间几乎看不出差别，
## 而"快死了要撤"必须是一眼能看出来的信号
func _hp_color(ratio: float) -> Color:
	if ratio > HP_WARN_RATIO:
		return HP_HEALTHY_COLOR
	if ratio > HP_CRITICAL_RATIO:
		return HP_WARN_COLOR
	return HP_CRITICAL_COLOR


## 选中单位的 id 集合。用 id 而不是对象引用比较：
## 模拟层每次 units() 都返回新数组，但 Unit 引用本身稳定，
## 这里仍走 id 是因为它同时能防住"GameState 里残留了已阵亡对象"的情况
func _selected_unit_ids() -> Dictionary:
	var ids := {}
	for item in GameState.selected_units():
		if not (item is Unit):
			continue
		var selected_unit := item as Unit
		if selected_unit != null:
			ids[selected_unit.id] = true
	return ids


## 主相机。空值由调用方处理（_draw 直接返回），这里不 push_error：
## 相机还没装配好就刷屏报错，只会掩盖真正的装配问题
func _current_camera() -> Camera3D:
	var vp := get_viewport()
	if vp == null:
		return null
	return vp.get_camera_3d()


# ---------------------------------------------------------------- 信号


func _on_unit_died(unit: Unit, killer_id: int) -> void:
	if unit == null:
		return
	var text := "%s #%d 战损" % [unit.def_id, unit.id]
	if killer_id >= 0:
		text += "（击毁者 #%d）" % killer_id
	_notices.append({"text": text, "left": TOAST_DURATION})
	if _notices.size() > MAX_NOTICES:
		_notices.pop_front()


## 只推进提示的剩余寿命，不碰模拟层
func _advance_notices(delta: float) -> void:
	if _notices.is_empty():
		return
	var alive: Array[Dictionary] = []
	for notice in _notices:
		var left := float(notice.get("left", 0.0)) - delta
		if left <= 0.0:
			continue
		notice["left"] = left
		alive.append(notice)
	_notices = alive


## 断开旧会话的 unit_died。
## 不这么做的话，换关卡后旧会话（RefCounted，可能还有人持有）继续发信号，
## HUD 会播报上一个战场的战损
func _unbind_session() -> void:
	var old := _session
	_session = null
	if old == null:
		return
	if not old.has_signal(&"unit_died"):
		return
	var handler := Callable(self, &"_on_unit_died")
	if old.is_connected(&"unit_died", handler):
		old.disconnect(&"unit_died", handler)
