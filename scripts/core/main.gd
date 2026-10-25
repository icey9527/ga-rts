extends Node

## 主场景装配器（entry point）。只负责把子场景装进 World，不含任何游戏逻辑。
##
## 节点树约定（docs/ARCHITECTURE.md：Main → World + GUI）：
##   Main (Node)      ← 本脚本
##     World (Node3D) ← 关卡 / 战斗场景挂在这里，换关卡 = 换 World 的子节点
##     GUI (CanvasLayer) ← HUD，由 UI 层在后续卡接管
##
## 场景引用走 @export（在 main.tscn 里指定），因此代码里不出现资源路径字面量
## （硬规则 5 的同一条精神：路径属于数据，不属于代码）。

@export var battle_scene: PackedScene

@onready var _world: Node3D = $World


func _ready() -> void:
	if battle_scene == null or not battle_scene.can_instantiate():
		push_error("[main] battle_scene 未指定或不可实例化，World 保持为空")
		return
	_world.add_child(battle_scene.instantiate())
