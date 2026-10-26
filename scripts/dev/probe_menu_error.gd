extends Node3D

## 复现：右键菜单 → 选项 → 左键确认，全过程有没有报错。
## 用真实 battle.tscn（相机/投影/输入都是装配好的），不手搓依赖。

const BATTLE := "res://scenes/battle/battle.tscn"

func _ready() -> void:
	await get_tree().process_frame
	print("[probe_menu] ==== 菜单→指选→确认 全过程 ====")

	var packed := load(BATTLE) as PackedScene
	var battle := packed.instantiate()
	add_child(battle)
	for i in 5:
		await get_tree().process_frame

	var router: InputRouter = battle.get_node_or_null(^"InputRouter")
	var menu: CommandMenu = battle.get_node_or_null(^"HudLayer/CommandMenu")
	var session: BattleSession = battle.session()
	if router == null or menu == null or session == null:
		print("[probe_menu] !! 节点缺失 router=%s menu=%s session=%s" % [
			str(router != null), str(menu != null), str(session != null)])
		get_tree().quit(1)
		return

	# 选中一艘己方单位
	var mine: Array[Unit] = []
	for unit in session.units():
		if unit.team == 0:
			mine.append(unit)
	if mine.is_empty():
		print("[probe_menu] !! 没有己方单位")
		get_tree().quit(1)
		return
	router.set_selection([mine[0]])
	print("[probe_menu] 选中 #%d %s" % [mine[0].id, mine[0].def_id])

	# 1) 右键（在屏幕中心附近）
	router._handle_right_click(Vector2(480.0, 270.0))
	print("[probe_menu] 右键后：菜单项数 = %d" % menu.entry_count())

	# 2) 点第一项（移动）→ 应进入指选
	if menu.entry_count() > 0:
		menu._on_id_pressed(0)
	print("[probe_menu] 选‘移动’后：targeting=%s kind=%s" % [
		str(router.targeting_active()), str(router.targeting_kind())])

	# 关键：指选态下停多帧。无头模式不渲染，_draw() 不会执行；
	# 带窗口跑才会真正走箭头/准星的绘制代码（报错就在那一层）。
	for i in 20:
		await get_tree().process_frame
	# 截一张图存证：验证箭头与准星真的画出来了
	var shot := get_viewport().get_texture().get_image()
	if shot != null:
		var out_dir := ProjectSettings.globalize_path("res://tools/temp/capture")
		DirAccess.make_dir_recursive_absolute(out_dir)
		var path := out_dir + "/targeting.png"
		shot.save_png(path)
		print("[probe_menu] 指选态停 20 帧完毕（已跑过 _draw），截图 %s" % path)

	# 3) 左键确认（指选态下这一下是确认，不是选择）
	router._handle_left_click(Vector2(600.0, 350.0), false, false)
	print("[probe_menu] 左键确认后：targeting=%s" % str(router.targeting_active()))
	for i in 5:
		await get_tree().process_frame

	# 4) 再试一次：菜单选‘停止’（立即执行路径）
	router._handle_right_click(Vector2(480.0, 270.0))
	var last := menu.entry_count() - 1
	if last >= 0:
		menu._on_id_pressed(last)
	print("[probe_menu] 选‘停止’后：targeting=%s" % str(router.targeting_active()))

	for i in 5:
		await get_tree().process_frame
	print("[probe_menu] 结束")
	get_tree().quit(0)
