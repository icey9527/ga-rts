class_name RtsCameraRig
extends Node3D

## 相机装配器：一台 3D 焦点轨道相机 + 一台 2D 正交俯视相机，同一时刻只有一台 current。
##
## ADR-0001 的关键约束在这里落地：
##   - 模拟层只有一套 3D 数据，模式切换**不是**场景重载，只是换镜头
##   - 模式切换时焦点位置不变（ADR-0002 的体验要求：换视图不该丢掉"我在看哪里"）
##   - 上层只从 view_projection() 拿投影，拿不到"现在是 2D 还是 3D"这件事
##
## 「禁止 if is_2d」这条纪律指的是**业务代码**（选择 / 命令 / UI）。
## 本文件是两台相机之间的适配器，分支只能出现在这里 —— 这是适配器的职责，
## 不是违规。谁想在外面写 if mode == VIEW_2D，正确答案是把那段逻辑搬进来。
##
## 节点树（见 scenes/camera/rts_camera.tscn）：
##   CameraRig (Node3D)      ← 本脚本
##     Cam3D (Node3D)        ← RtsCamera3D
##       Camera3D
##     Cam2D (Node3D)        ← RtsCamera2D
##       Camera3D

## 视图模式切换完成（过渡动画落地后，这条信号会在插值结束时才发）
signal mode_changed(mode: int)

enum ViewMode {
	VIEW_3D = 0,  ## 焦点轨道透视（接战 / 必杀 / 过场）
	VIEW_2D = 1,  ## 正交俯视（全局指挥）
}

## 模式切换过渡时长（docs/controls.md / ADR-0001：0.4 s 平滑插值）
const TRANSITION_SECONDS := 0.4

@onready var camera_3d: RtsCamera3D = $Cam3D
@onready var camera_2d: RtsCamera2D = $Cam2D

var _mode := ViewMode.VIEW_3D
## 全项目唯一一份对外投影。上层拿到的始终是同一个实例，模式切换只是重绑它内部的相机。
var _view_projection := ViewProjection.new()


func _ready() -> void:
	if camera_3d == null or camera_2d == null:
		push_error("[RtsCameraRig] 缺少 Cam3D / Cam2D 子节点，相机装配失败")
		return
	# 初始模式直接生效，不走过渡（进场不该有一段动画）
	_apply_mode(focus_position())


## 切换模式。焦点位置在两台相机之间原样交接。
func set_mode(mode: ViewMode) -> void:
	if mode == _mode:
		return
	var focus := focus_position()
	_mode = mode
	_apply_mode(focus)


## Tab 循环：3D → 2D → 3D（"自动"档由 T-1.3 的 InputRouter / SceneDirector 决定）
func toggle_mode() -> void:
	set_mode(ViewMode.VIEW_2D if _mode == ViewMode.VIEW_3D else ViewMode.VIEW_3D)


func mode() -> ViewMode:
	return _mode


## 诊断用。业务代码**不得**据此分支（那正是 ViewProjection 要消灭的东西）。
func is_2d() -> bool:
	return _mode == ViewMode.VIEW_2D


## 对外唯一投影入口。选择、命令、UI、射程圈全从这里取，不自己算三角函数。
func view_projection() -> ViewProjection:
	return _view_projection


## 玩家当前正在看哪里（= 当前相机的焦点，平滑中的话是"此刻的位置"而非目标）
func focus_position() -> Vector3:
	return _active_focus()


## 平滑聚焦（空格聚焦所选 / 双击单位 / 剧情运镜）
func focus_on(world_pos: Vector3, instant := false) -> void:
	if _mode == ViewMode.VIEW_2D:
		camera_2d.focus_on(world_pos, instant)
	else:
		camera_3d.focus_on(world_pos, instant)


## 直接切到某个模式并强制重放装配（调试 / 验证场景用）
func force_mode(mode: ViewMode) -> void:
	var focus := focus_position()
	_mode = mode
	_apply_mode(focus)


## 把模式落到节点状态：current 相机、输入闸门、焦点接力、投影重绑。
func _apply_mode(focus: Vector3) -> void:
	# 焦点接力：两台相机的焦点始终一致，切换时画面中心才不会跳
	camera_3d.snap_focus(focus)
	camera_2d.snap_focus(focus)

	camera_3d.accept_input = _mode == ViewMode.VIEW_3D
	camera_2d.accept_input = _mode == ViewMode.VIEW_2D
	camera_3d.set_process(_mode == ViewMode.VIEW_3D)
	camera_2d.set_process(_mode == ViewMode.VIEW_2D)

	var camera := _active_camera()
	if camera == null:
		push_error("[RtsCameraRig] 当前相机节点没有 Camera3D，投影保持失效")
		return
	camera.make_current()

	_view_projection.setup(camera)
	_view_projection.set_reference_height(focus.y)

	# TODO(T-1.3)：0.4 s 过渡 —— 焦点不动，把轨道半径 / 俯仰插值到正交等效视角 + 音效。
	# 本卡先直接切换；TRANSITION_SECONDS 常量已留好，别在别处硬编码 0.4。
	mode_changed.emit(_mode)


## 当前相机的 Camera3D
func _active_camera() -> Camera3D:
	if _mode == ViewMode.VIEW_2D:
		return camera_2d.camera()
	return camera_3d.camera()


## 当前相机的焦点
func _active_focus() -> Vector3:
	if _mode == ViewMode.VIEW_2D:
		return camera_2d.focus_position
	return camera_3d.focus_position
