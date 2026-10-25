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

## 要显示的战斗会话。null = 未接线，此时 _draw 直接返回（不是错误状态）
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

		# 画序：圆环 → 血条 → 圆点。圆点最后画，保证它永远是队色的视觉锚点
		if selected.has(unit.id):
			draw_arc(screen, SELECT_RING_RADIUS, 0.0, TAU,
				SELECT_RING_POINTS, SELECT_COLOR, SELECT_RING_WIDTH, true)
		_draw_health_bar(screen, unit, font)
		draw_circle(screen, MARKER_RADIUS, _team_color(unit.team))

	_draw_summary(units.size(), drawn, team_counts, selected.size(), font)


# ---------------------------------------------------------------- 单单位绘制


## 血条：背景恒画（给出"这里有多长"的基准），前景按血量比例裁宽。
## 不画满就补一条底色，否则低血量时玩家分不清"血条短"和"没有血条"。
func _draw_health_bar(at: Vector2, unit: Unit, font: Font) -> void:
	var ratio := clampf(unit.hp_ratio(), 0.0, 1.0)
	var bar_rect := Rect2(
		Vector2(at.x - HP_BAR_WIDTH * 0.5, at.y - MARKER_RADIUS - HP_BAR_GAP),
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
	draw_string(font, Vector2(SUMMARY_MARGIN, SUMMARY_MARGIN + LABEL_FONT_SIZE), line,
		HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, SUMMARY_COLOR)

	# 战损播报：unit_died 是它唯一的来源。故意不做队列动画，
	# 只让 alpha 随剩余时间淡出 —— 一眼能看出"刚没的是谁"就够了
	var y := SUMMARY_MARGIN + LABEL_FONT_SIZE * 2.0
	for notice in _notices:
		var alpha := clampf(float(notice.get("left", 0.0)) / TOAST_DURATION, 0.0, 1.0)
		var color := TOAST_COLOR
		color.a = alpha
		draw_string(font, Vector2(SUMMARY_MARGIN, y), String(notice.get("text", "")),
			HORIZONTAL_ALIGNMENT_LEFT, -1, LABEL_FONT_SIZE, color)
		y += LABEL_FONT_SIZE + 2.0


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
