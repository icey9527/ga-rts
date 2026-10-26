class_name TargetingOverlay
extends Control

## 指选模式的视觉层（原版 tactical_arrows + 准星 的最小等价物）。
##
## 玩家从右键菜单选定“移动/攻击/攻击移动”后，原版会进入指选状态：
##   · 每个待令单位向鼠标画一根箭头
##   · 鼠标准星随目标变化（锁到敌人 → 双环；空地 → 小圈+十字）
##   · 顶部提示“选择目标中… 左键确认 | 右键取消”
##
## 我们之前没有这一层 —— 菜单点完就立即下令，玩家完全看不到“我要把命令下到哪”，
## 这就是“点了按钮没反馈”的主因。
##
## 本类是纯表现：只读 router 的状态、GameState 的选中、ViewProjection 的投影，
## 自己不产生任何命令。

## 箭头颜色按命令种类区分（对齐原版的配色语言）
const KIND_COLORS := {
	&"cmd_move": Color(0.25, 0.65, 1.0),
	&"cmd_attack": Color(1.0, 0.16, 0.12),
	&"cmd_attack_move": Color(1.0, 0.5, 0.2),
}
const DEFAULT_COLOR := Color(0.85, 0.9, 1.0)
## 箭头尖端停在准星外这么多像素，避免盖住准星
const ARROW_TIP_GAP := 20.0
## 箭头三角的尺寸
const ARROW_HEAD := 11.0
const LINE_WIDTH := 2.0
## 准星尺寸
const CROSS_RADIUS := 10.0
const CROSS_TICK := 8.0
const LOCK_INNER := 9.0
const LOCK_OUTER := 18.0

var _router: InputRouter = null
var _session: BattleSession = null
var _projection: ViewProjection = null
## 鼠标悬停到的敌人（用于把准星画成“已锁定”双环）
var _hover_hostile := false


func _ready() -> void:
	# 铺满全屏但不吃鼠标：命令确认仍然由 InputRouter 处理
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = true


## 注入依赖（三者都可为 null，绘制时逐项判空）
func bind(router: InputRouter, session: BattleSession, projection: ViewProjection) -> void:
	_router = router
	_session = session
	_projection = projection


func _process(_delta: float) -> void:
	# 只有指选时才需要重绘（每帧都在动：单位在飞、鼠标在移）
	if _router != null and _router.targeting_active():
		queue_redraw()


func _draw() -> void:
	if _router == null or not _router.targeting_active():
		return
	if _projection == null or not _projection.is_ready():
		return

	var mouse := get_local_mouse_position()
	var kind := _router.targeting_kind()
	var color: Color = KIND_COLORS.get(kind, DEFAULT_COLOR)

	# 1. 每个选中单位 → 鼠标，一根箭头
	for unit in _selected_units():
		if _projection.is_position_behind(unit.position):
			continue
		var from: Vector2 = _projection.world_to_screen(unit.position)
		_draw_arrow(from, mouse, color)

	# 2. 准星（悬停在敌人身上时画成锁定双环）
	_hover_hostile = _is_hostile_under(mouse)
	_draw_crosshair(mouse, _hover_hostile)

	# 3. 顶部提示
	_draw_hint(kind)


## 箭头：线 + 尖端三角。尖端停在准星外 ARROW_TIP_GAP 像素。
func _draw_arrow(from: Vector2, to: Vector2, color: Color) -> void:
	var dir := to - from
	var length := dir.length()
	if length <= ARROW_TIP_GAP + 1.0:
		return
	var unit_dir := dir / length
	var tip := to - unit_dir * ARROW_TIP_GAP
	draw_line(from, tip, color, LINE_WIDTH, true)
	# 三角：两条边指向回箭身
	var back := tip - unit_dir * ARROW_HEAD
	var side := Vector2(-unit_dir.y, unit_dir.x) * (ARROW_HEAD * 0.45)
	draw_line(tip, back + side, color, LINE_WIDTH, true)
	draw_line(tip, back - side, color, LINE_WIDTH, true)


func _draw_crosshair(at: Vector2, locked: bool) -> void:
	var color := Color(1.0, 0.25, 0.2) if locked else Color(0.9, 0.95, 1.0, 0.9)
	if locked:
		# 已锁定：双环
		draw_arc(at, LOCK_OUTER, 0.0, TAU, 32, color, 2.0, true)
		draw_arc(at, LOCK_INNER, 0.0, TAU, 24, color, 2.0, true)
	else:
		# 未锁定：小圈 + 十字
		draw_arc(at, CROSS_RADIUS, 0.0, TAU, 20, color, 1.5, true)
		draw_line(at + Vector2(-CROSS_TICK, 0), at + Vector2(CROSS_TICK, 0), color, 1.0, true)
		draw_line(at + Vector2(0, -CROSS_TICK), at + Vector2(0, CROSS_TICK), color, 1.0, true)


func _draw_hint(kind: StringName) -> void:
	var font := ThemeDB.fallback_font
	if font == null:
		return
	var verb := "选择目标"
	match kind:
		&"cmd_move":
			verb = "移动到"
		&"cmd_attack":
			verb = "攻击"
		&"cmd_attack_move":
			verb = "攻击移动至"
	var text := "%s…  左键确认 | 右键取消" % verb
	var size := get_viewport_rect().size
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16)
	var at := Vector2((size.x - text_size.x) * 0.5, size.y * 0.5 - 120.0)
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 16, Color(1.0, 0.92, 0.5))


func _selected_units() -> Array[Unit]:
	var out: Array[Unit] = []
	for item in GameState.selected_units():
		if item is Unit and (item as Unit).alive:
			out.append(item)
	return out


## 鼠标下面是不是敌人（用来切换准星形态）
func _is_hostile_under(_screen: Vector2) -> bool:
	if _session == null:
		return false
	# 借输入层自己的判定口径：它已经处理了船体半径与敌我
	return _router.hovering_hostile()


## 验证用：让场景能读到当前是否处于锁定态
func hover_is_hostile() -> bool:
	return _hover_hostile
