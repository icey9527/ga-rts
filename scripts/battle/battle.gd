extends Node3D

## 战斗场景空壳。本卡只提供容器 + 输入装配，不含任何逻辑（逻辑归 L1：scripts/battle/）。
##
## 节点树约定：
##   Battle (Node3D)        ← 本脚本，战斗场景根
##     World (Node3D)       ← 静态场景：地形 / 障碍 / 天空
##     Units (Node3D)       ← 单位表现节点（只读模拟数据做插值，硬规则 4）
##     Camera (Node3D)      ← RtsCameraRig：2D/3D 双相机 + 唯一 ViewProjection（T-1.2）
##     InputRouter (Node)   ← 输入路由（T-1.3）：action → 相机 / 选择 / CommandBus
##
## 相机由本场景实例化（scenes/camera/rts_camera.tscn），上层只通过它的
## view_projection() 取投影，因此不知道当前是 2D 还是 3D（ADR-0001）。
## 单位 / 导航的挂载点由后续卡接进来。
##
## 输入的单向流（本文件是唯一的接线处）：
##   input_router.setup(camera_rig, camera_rig.view_projection())
## 同时把相机自带的输入关掉（battle.tscn 里 Camera / Cam3D / Cam2D 的 accept_input = false，
## InputRouter.setup 再兜一次），否则同一个鼠标拖拽会既平移相机又走路由，变成两倍速。

@onready var world: Node3D = $World
@onready var units: Node3D = $Units
@onready var camera_rig: RtsCameraRig = $Camera
@onready var input_router: InputRouter = $InputRouter


func _ready() -> void:
	assert(world != null, "Battle 缺少 World 容器")
	assert(units != null, "Battle 缺少 Units 容器")
	assert(camera_rig != null, "Battle 缺少 Camera（RtsCameraRig）")
	assert(input_router != null, "Battle 缺少 InputRouter")
	# 依赖注入，不在 InputRouter 里写死节点路径
	input_router.setup(camera_rig, camera_rig.view_projection())
