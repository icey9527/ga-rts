class_name DeathBurst
extends Node3D

## 退场爆炸：单位阵亡时在它最后的位置放一个扩张 + 淡出的光球。
##
## 之前 unit_died 只用来释放模型，**没有任何爆炸表现** —— 船"啪"一下消失，
## 玩家根本看不出发生了什么。这是"没做到"。
##
## 实现取舍：程序化球体 + 手动动画，不用 S0.5 那 208 个特效公告板 GLB。
##   理由：那些资产是为原版的公告板精灵管线烘的，接进来要处理朝向/帧序/材质，
##   而"扩张变淡的球"在 RTS 视距下已经足够读出"这里炸了一艘船"。
##   等 S5 做特效系统时再统一换成资产版本。

## 爆炸持续时间（秒）
const LIFETIME := 0.85
## 起始与结束半径相对舰体半径的倍数
const START_SCALE := 0.35
const END_SCALE := 2.6

var _age := 0.0
var _base_radius := 10.0
var _mesh: SphereMesh = null
var _material: StandardMaterial3D = null


## 在 world_position 处炸出一团，半径按舰体尺寸缩放（大舰炸得大）
func setup(world_position: Vector3, ship_radius: float, tint: Color) -> void:
	global_position = world_position
	_base_radius = maxf(ship_radius, 6.0)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.albedo_color = Color(tint.r, tint.g, tint.b, 0.95)
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 发光让它在深空背景上"炸得出来"，不依赖场景光照
	_material.emission_enabled = true
	_material.emission = tint
	_material.emission_energy_multiplier = 3.0

	_mesh = SphereMesh.new()
	_mesh.radius = 1.0
	_mesh.height = 2.0
	_mesh.radial_segments = 16
	_mesh.rings = 8

	var instance := MeshInstance3D.new()
	instance.mesh = _mesh
	instance.material_override = _material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	_apply_visual()


func _process(delta: float) -> void:
	_age += delta
	if _age >= LIFETIME:
		queue_free()
		return
	_apply_visual()


func _apply_visual() -> void:
	var t := clampf(_age / LIFETIME, 0.0, 1.0)
	# 半径用 ease-out，爆炸一开始扩得快、后面收尾 —— 符合爆发直觉
	var scale_radius := _base_radius * lerpf(START_SCALE, END_SCALE, sqrt(t))
	scale = Vector3.ONE * scale_radius
	if _material != null:
		# 前 15% 保持全亮（爆闪），之后线性淡出
		var alpha := 1.0 if t < 0.15 else lerpf(1.0, 0.0, (t - 0.15) / 0.85)
		_material.albedo_color = Color(
			_material.albedo_color.r, _material.albedo_color.g,
			_material.albedo_color.b, alpha)


## 验证用：当前是否还在播
func is_playing() -> bool:
	return _age < LIFETIME
