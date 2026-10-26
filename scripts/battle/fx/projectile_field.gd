class_name ProjectileField
extends MultiMeshInstance3D

## 弹道表现层：把 ProjectileManager 里的弹体画出来。
##
## 之前弹体只有**数据**（Projectile 是纯 RefCounted），从来没有任何东西渲染它 ——
## 玩家看不到弹道，只能看到目标莫名掉血。这是"没做到"，不是 bug。
##
## 实现取舍：每帧重建 MultiMesh 的实例（而不是为每发弹 `new 一个节点`）。
##   · 弹体生命周期短（1~2 秒）、同时在场几十到上千发，逐帧 new/free 会频繁分配
##   · MultiMesh 一次 draw call 画完，重建变换数组在 CPU 侧只是几十~几千次向量运算
##   · 不做增量维护：增量要跟踪"哪发弹是新出现的 / 哪发消失了"，
##     而弹体在命中瞬间被移除，状态跟踪很容易出漏删（漏删就是天上的幽灵弹道）
##
## **尺寸是刻意夸张的**：真实弹体半径 0.8 m，在 3000 m 视距下不到一个像素。
## 这里把显示长度放大到 14 m（约 1/4 个 ou05 舰长），才能让玩家看清"谁在朝谁开火"。
## 这是表现层惯例（真实弹道武器在即时战略里都必须夸张），不是物理尺寸错误。

## 弹体显示长度（米，沿飞行方向）
const RENDER_LENGTH := 20.0
## 弹体显示粗细（米）
const RENDER_WIDTH := 4.0
## 预分配的实例上限（仅作为安全上限，防止异常数据把显存写爆）。
const MAX_INSTANCES := 512
## 队色：team 0 青、team 1 橙红，与 HUD 标记同色系
const TEAM_COLORS := {
	0: Color(0.35, 0.95, 1.0),
	1: Color(1.0, 0.55, 0.35),
}

var _session: BattleSession = null
var _materials: Dictionary = {}
## 本帧实际写入的弹体数 / 方向 / 颜色。
## 不靠 MultiMesh 读回来验证 —— 实测 `get_instance_transform/color` 在
## 重新分配 / 未渲染的 MultiMesh 上读回的是默认值（单位矩阵、黑包），
## 那测的是驱动的内部状态，不是我们的逻辑。这里直接留自己写下的真值。
var _last_count := 0
var _last_dirs: Array[Vector3] = []
var _last_colors: Array[Color] = []


func _ready() -> void:
	# 一个细长的盒子沿 -Z 伸展，用 looking_at 对齐飞行方向
	var box := BoxMesh.new()
	box.size = Vector3(RENDER_WIDTH, RENDER_WIDTH, RENDER_LENGTH)
	# **必须自发光**：深空场景里受光材质的弹道几乎是黑的，玩家根本看不见。
	# unshaded + 顶点色（MultiMesh 的实例颜色）才能让队色直接显示出来。
	var lit := StandardMaterial3D.new()
	lit.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	lit.vertex_color_use_as_albedo = true
	lit.emission_enabled = true
	lit.emission = Color.WHITE
	lit.emission_energy_multiplier = 2.0
	lit.cull_mode = BaseMaterial3D.CULL_DISABLED
	material_override = lit

	multimesh = MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = box
	# 不用 visible_instance_count：实测写入后读回恒为 0（一个实例都不画）。
	# 直接用 instance_count 控制画面上的数量；颜色/变换每帧都会全部重写，
	# 所以重分配导致的数据清空对我们没影响。
	multimesh.instance_count = 0
	# 弹道不投阴影：体积小、数量多，投影只会让画面变脏且拖慢
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 不用 AABB 剔除：实例全程在变，包围盒每帧失效，反而会被误剔除
	extra_cull_margin = 1.0e9


func bind_session(session: BattleSession) -> void:
	_session = session


func _process(_delta: float) -> void:
	if _session == null:
		multimesh.instance_count = 0
		return
	var projectiles := _session.projectiles().projectiles()
	var count := mini(projectiles.size(), MAX_INSTANCES)
	if multimesh.instance_count != count:
		multimesh.instance_count = count
	_last_count = count
	_last_dirs.clear()
	_last_colors.clear()
	for i in count:
		var p: Projectile = projectiles[i]
		var dir := p.velocity
		if dir.length_squared() < 1.0e-6:
			dir = Vector3.FORWARD
		dir = dir.normalized()
		var basis := Basis.looking_at(dir, Vector3.UP)
		multimesh.set_instance_transform(i, Transform3D(basis, p.position))
		var tint: Color = TEAM_COLORS.get(p.team, Color.WHITE)
		multimesh.set_instance_color(i, tint)
		_last_dirs.append(dir)
		_last_colors.append(tint)


## 给验证场景 / 调试用：当前实际渲染的弹体数
func rendered_count() -> int:
	return _last_count


## 本帧第 index 发弹的飞行方向（验证用）
func rendered_direction(index: int) -> Vector3:
	return _last_dirs[index] if index >= 0 and index < _last_dirs.size() else Vector3.ZERO


## 本帧第 index 发弹的颜色（验证用）
func rendered_color(index: int) -> Color:
	return _last_colors[index] if index >= 0 and index < _last_colors.size() else Color.BLACK
