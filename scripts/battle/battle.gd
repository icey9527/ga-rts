extends Node3D

## 战斗场景空壳。本卡只提供容器，不含任何逻辑（逻辑归 L1：scripts/battle/）。
##
## 节点树约定：
##   Battle (Node3D)      ← 本脚本，战斗场景根
##     World (Node3D)     ← 静态场景：地形 / 障碍 / 天空
##     Units (Node3D)     ← 单位表现节点（只读模拟数据做插值，硬规则 4）
##     Camera (Node3D)    ← RtsCameraRig：2D/3D 双相机 + 唯一 ViewProjection（T-1.2）
##
## 相机由本场景实例化（scenes/camera/rts_camera.tscn），上层只通过它的
## view_projection() 取投影，因此不知道当前是 2D 还是 3D（ADR-0001）。
## 单位 / 导航的挂载点由后续卡接进来。
##
## 这里只做容器存在性断言：空容器被悄悄漏掉，后面会变成"东西怎么不出现在屏幕上"的谜案。

@onready var world: Node3D = $World
@onready var units: Node3D = $Units
@onready var camera_rig: RtsCameraRig = $Camera


func _ready() -> void:
	assert(world != null, "Battle 缺少 World 容器")
	assert(units != null, "Battle 缺少 Units 容器")
	assert(camera_rig != null, "Battle 缺少 Camera（RtsCameraRig）")
