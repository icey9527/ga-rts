extends Node3D

## 回归：右键命令菜单（旧版 `show_context_menu` 的等价物）。
##
## 验证三件事：
##   1. open_at 按 entries 建出菜单项，kind 顺序正确
##   2. 选中某一项 → 发出 command_chosen，带上对应的 kind/options
##   3. 注入 InputRouter 后 → 菜单信号真的会走 CommandBus 发出命令
##
## 注意：本场景**不弹真菜单**去点，只驱动数据流。
## 点真实像素属于 UI 交互，用 headless 测它既脆又慢；这里测的是接线与分发。

const MENU_SCENE_SCRIPT := "res://scripts/ui/command_menu.gd"

var _checks := 0
var _fails := 0
var _issued: Array = []


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_menu] ==== 右键命令菜单 ====")

	# 1. 菜单本身
	var menu := CommandMenu.new()
	add_child(menu)
	await get_tree().process_frame

	var got: Array = []
	menu.command_chosen.connect(func(kind: StringName, options: Dictionary) -> void:
		got.append({"kind": kind, "options": options}))

	menu.open_at(Vector2(200.0, 150.0), [
		{"label": "移动", "kind": &"cmd_move", "options": {"point": Vector3.ZERO}},
		{"label": "攻击移动", "kind": &"cmd_attack_move", "options": {"point": Vector3.ONE}},
		{"label": "停止", "kind": &"cmd_stop", "options": {}},
	])
	_expect(menu.entry_count() == 3, "建出 3 个菜单项（实际 %d）" % menu.entry_count())
	_expect(menu.entry_kind(0) == &"cmd_move", "第 1 项是移动（实际 %s）" % menu.entry_kind(0))
	_expect(menu.entry_kind(1) == &"cmd_attack_move",
		"第 2 项是攻击移动（实际 %s）" % menu.entry_kind(1))
	_expect(menu.entry_kind(2) == &"cmd_stop", "第 3 项是停止（实际 %s）" % menu.entry_kind(2))

	# 2. 选中「停止」
	menu._on_id_pressed(2)
	_expect(got.size() == 1, "选中后发出 1 次 command_chosen（实际 %d）" % got.size())
	if got.size() == 1:
		_expect(got[0]["kind"] == &"cmd_stop",
			"发出的是停止（实际 %s）" % got[0]["kind"])

	# 3. 注入 InputRouter → 信号走 CommandBus
	var router := InputRouter.new()
	add_child(router)
	var unit := Unit.new(7, "test")
	unit.alive = true
	unit.position = Vector3.ZERO
	router.set_selection([unit])
	router.set_command_menu(menu)

	var handler := Callable(self, &"_on_command_issued")
	if not CommandBus.command_issued.is_connected(handler):
		CommandBus.command_issued.connect(handler)

	menu.command_chosen.emit(&"cmd_move", {"point": Vector3(0.0, 0.0, -500.0)})
	_expect(_issued.size() == 1, "菜单命令经 InputRouter 发到了 CommandBus（%d 次）" % _issued.size())
	if _issued.size() == 1:
		_expect(_issued[0] == &"cmd_move", "CommandBus 收到的是 cmd_move（实际 %s）" % _issued[0])

	# 4. 传 null 摘掉菜单 → 回到直接下令模式（不再走菜单）
	router.set_command_menu(null)
	menu.command_chosen.emit(&"cmd_stop", {})
	_expect(_issued.size() == 1, "摘掉菜单后旧信号不再触发命令（%d 次）" % _issued.size())

	if CommandBus.command_issued.is_connected(handler):
		CommandBus.command_issued.disconnect(handler)

	print("[verify_menu] ---- 结果 ----")
	print("[verify_menu]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_menu] PASS")
		get_tree().quit(0)
	else:
		print("[verify_menu] FAIL")
		get_tree().quit(1)


func _on_command_issued(_target: Variant, kind: StringName, _options: Dictionary) -> void:
	_issued.append(kind)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_menu]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_menu]   FAIL  %s" % what)
