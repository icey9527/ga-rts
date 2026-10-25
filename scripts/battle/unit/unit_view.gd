class_name UnitView
extends Node3D

## 单位表现节点（L2 表现层，ARCHITECTURE 硬规则 4：**只读**）。
##
## 只读 Unit 的 position / forward / speed 做插值显示；本类里没有任何一处给 unit 的字段赋值。
## 位置/朝向用指数平滑跟随（帧率无关），因此模拟 60 Hz、渲染任意帧率都不会抖。
## 想"看起来该动一下"的东西（后坐、晃动、倾斜）都加在这一层，绝不回写模拟字段。
##
## 节点树（scenes/units/unit_base.tscn）：
##   UnitBase (Node3D)      ← 本脚本，只承担姿态（position / basis）
##     Model (MeshInstance3D) ← 模型挂载点。场景里放一个 BoxMesh 占位，
##                              真实模型由 apply_model() / apply_model_from_registry() 注入
##
## 模型路径**必须**从注册表取（硬规则 5 / ADR-0008）：GameState.registry().asset(def_id)。
## 本文件里刻意不出现任何 res:// 资源路径字面量，也没有 .glb 扩展名的假设
## （注册表存的是不带扩展名的路径，这里按 MODEL_EXTENSIONS 顺序试探）。

## 位置 / 朝向的指数收敛速度（1/s）。越大越"贴身"，越小越"重"
@export var follow_sharpness := 6.0
## 与模拟位置差超过这个距离就直接贴上去（传送 / 休眠结束 / 生成首帧），
## 否则平滑跟随会在战场上拖一条长线
@export var snap_distance := 5000.0

## 注册表路径不带扩展名，这里按顺序试探（与 Registry.ASSET_EXTENSIONS 的模型子集一致）
const MODEL_EXTENSIONS: Array[String] = ["glb", "gltf", "scn", "tscn", "res"]
## 姿态"贴着世界 up 时"改用这个 up，避免 Basis.looking_at 退化
const FALLBACK_UP := Vector3.BACK
## 视为机头与世界 up 共线的阈值
const UP_DEGENERATE_DOT := 0.999

@onready var _model: MeshInstance3D = get_node_or_null(^"Model") as MeshInstance3D

var _unit: Unit = null
var _render_position := Vector3.ZERO
var _render_forward := Unit.DEGENERATE_FORWARD
var _model_path := ""


func _process(delta: float) -> void:
	sync_visual(delta)


# ---------------------------------------------------------------- 绑定


## 绑定一艘模拟单位并立刻贴上去（首帧不插值，避免从原点飞过来）。
func bind(unit: Unit) -> void:
	_unit = unit
	if unit == null:
		return
	_render_position = unit.position
	_render_forward = unit.forward
	_apply_render_transform()


## 当前绑定的单位（只读；验证用例用它比对"没有被回写"）
func unit() -> Unit:
	return _unit


# ---------------------------------------------------------------- 模型注入


## 注入模型。glb_path 由调用方给（注册表解析后的路径，可带或不带扩展名）。
func apply_model(glb_path: String) -> void:
	var trimmed := glb_path.strip_edges()
	if trimmed.is_empty():
		push_error("[UnitView] 模型路径为空")
		return
	var packed := _load_model(trimmed)
	if packed == null:
		push_error("[UnitView] 模型加载失败（试过 %s）" % _candidate_text(trimmed))
		return
	var model := _model_node()
	if model == null:
		push_error("[UnitView] 节点树里没有 Model（MeshInstance3D），无法挂模型")
		return
	_clear_model()
	var instance := packed.instantiate()
	if instance == null:
		push_error("[UnitView] 模型实例化失败: %s" % trimmed)
		return
	model.add_child(instance)
	_model_path = trimmed


## 从注册表解析本单位的模型路径再注入。这是**唯一**允许的取路径方式（硬规则 5）。
## 返回 true 表示模型已挂上。
func apply_model_from_registry() -> bool:
	if _unit == null:
		push_error("[UnitView] 先 bind(unit) 再解析模型（需要一个 def_id）")
		return false
	var registry := GameState.registry()
	if registry == null:
		push_error("[UnitView] Registry 未就绪，无法解析资产：%s" % _unit.def_id)
		return false
	var path := registry.asset(_unit.def_id)
	if path.strip_edges().is_empty():
		return false
	apply_model(path)
	return model_attached()


## 已挂上的模型路径（验证用例检查它来自注册表）
func model_path() -> String:
	return _model_path


## 是否已经挂了真实模型（占位 BoxMesh 不算）
func model_attached() -> bool:
	var model := _model_node()
	if model == null or _model_path.is_empty():
		return false
	return model.get_child_count() > 0


# ---------------------------------------------------------------- 插值（只读）


## 把渲染姿态朝模拟状态收敛。**只读 unit，不回写**。
## 单独抽出来是为了让验证场景能一帧一帧驱动它（不依赖引擎的 _process 节奏）。
func sync_visual(delta: float) -> void:
	if _unit == null:
		return
	var target_position := _unit.position
	if _render_position.distance_to(target_position) > snap_distance:
		_render_position = target_position
		_render_forward = _unit.forward
	else:
		# 帧率无关的指数插值：t = 1 - e^(-k·dt)
		var t := 1.0 - exp(-maxf(follow_sharpness, 0.0) * maxf(delta, 0.0))
		_render_position = _render_position.lerp(target_position, t)
		var blended := _render_forward.lerp(_unit.forward, t)
		if blended.length_squared() > 1.0e-8:
			_render_forward = blended.normalized()
	_apply_render_transform()


## 渲染用的位置（验证用例比对"跟随有滞后"）
func render_position() -> Vector3:
	return _render_position


## 渲染用的机头
func render_forward() -> Vector3:
	return _render_forward


# ---------------------------------------------------------------- 内部


func _apply_render_transform() -> void:
	var forward := _render_forward
	if not forward.is_finite() or forward.length_squared() <= 1.0e-8:
		forward = Unit.DEGENERATE_FORWARD
	else:
		forward = forward.normalized()
	var up := Vector3.UP
	if absf(forward.dot(up)) > UP_DEGENERATE_DOT:
		up = FALLBACK_UP
	# Basis.looking_at 让**-Z** 指向 forward（与 docs/scale-and-units.md 的机头约定一致）
	var target := Transform3D(Basis.looking_at(forward, up), _render_position)
	if is_inside_tree():
		# 模拟坐标就是世界坐标：走 global_* 让父容器的局部位移自动抵消
		global_transform = target
	else:
		# 还不在树里（验证场景的离线驱动）：没有父变换，局部即世界
		transform = target


func _model_node() -> MeshInstance3D:
	if _model == null:
		_model = get_node_or_null(^"Model") as MeshInstance3D
	return _model


## 清掉占位 mesh 与之前注入的模型（换型号 / 换皮肤时不留垃圾）
func _clear_model() -> void:
	var model := _model_node()
	if model == null:
		return
	for child in model.get_children():
		model.remove_child(child)
		child.queue_free()
	model.mesh = null
	_model_path = ""


## 按注册表约定（路径不带扩展名）逐个试探
func _load_model(path_no_extension: String) -> PackedScene:
	for candidate in _candidates(path_no_extension):
		if not ResourceLoader.exists(candidate, "PackedScene"):
			continue
		var packed := ResourceLoader.load(candidate, "PackedScene") as PackedScene
		if packed != null:
			return packed
	return null


func _candidates(path_no_extension: String) -> PackedStringArray:
	var out := PackedStringArray()
	# 注册表存的是不带扩展名的路径，所以补扩展名优先于原样路径
	for extension in MODEL_EXTENSIONS:
		out.append("%s.%s" % [path_no_extension, extension])
	out.append(path_no_extension)
	return out


func _candidate_text(path_no_extension: String) -> String:
	return ", ".join(_candidates(path_no_extension))
