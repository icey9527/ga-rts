class_name CommandMenu
extends PopupMenu

## 右键命令菜单（旧版 `sess:show_context_menu` 的等价物）。
##
## 旧版右键不直接下令，而是弹菜单，移动/攻击/攻击移动/停止都从菜单里选。
## 我们之前是右键直接下令 —— 少一次点击，但也失去了"能选什么"的可发现性：
## 新玩家根本不知道还能攻击移动。
##
## 用引擎自带的 PopupMenu 而不是自绘：菜单的弹出位置、键盘导航、
## 点击外部关闭、模态吃掉后面的输入，这些行为引擎都已经做对了，
## 自己重画一遍只会漏掉某一条（比如点外面没关掉，导致下一次点击被吞）。

## 玩家选了某一项。kind / options 与 CommandBus 的批次元素同构，
## 输入层拿到后直接 _issue()，不需要再做转换。
signal command_chosen(kind: StringName, options: Dictionary)

## 与 item index 一一对应的待发命令
var _pending: Array = []


func _ready() -> void:
	# 不重复连接：本节点可能在验证场景里被反复 setup
	if not id_pressed.is_connected(_on_id_pressed):
		id_pressed.connect(_on_id_pressed)


## 在屏幕坐标处弹出菜单。
## entries: [{ "label": String, "kind": StringName, "options": Dictionary }, ...]
func open_at(screen_pos: Vector2, entries: Array) -> void:
	clear()
	_pending.clear()
	for i in entries.size():
		var entry: Dictionary = entries[i]
		add_item(String(entry.get("label", "?")), i)
		_pending.append(entry)
	if _pending.is_empty():
		return
	position = Vector2i(screen_pos)
	popup()


## 当前菜单项数（验证用）
func entry_count() -> int:
	return _pending.size()


## 当前第 index 项的命令种类（验证用）
func entry_kind(index: int) -> StringName:
	if index < 0 or index >= _pending.size():
		return &""
	return _pending[index].get("kind", &"")


func _on_id_pressed(id: int) -> void:
	if id < 0 or id >= _pending.size():
		return
	var entry: Dictionary = _pending[id]
	command_chosen.emit(entry.get("kind", &""), entry.get("options", {}))
