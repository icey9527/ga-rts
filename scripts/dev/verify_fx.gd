extends Node3D

## 回归：弹道与退场爆炸这两块表现必须真的存在。
##
## 事故：Projectile 一直是纯数据（RefCounted），从没有任何东西渲染它；
## unit_died 只用来释放模型，没有爆炸。玩家看不到弹道、看不到爆船 —— 这是"没做到"。
##
## 本场景不靠截图碰运气，直接单元验证两个表现类：
##   · ProjectileField 建好 MultiMesh，且在场上有弹体时 rendered_count > 0
##   · DeathBurst 会扩张淡出、到期自行释放

var _checks := 0
var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	print("[verify_fx] ==== 弹道与爆炸表现 ====")
	await _case_projectile_field()
	await _case_death_burst()

	print("[verify_fx] ---- 结果 ----")
	print("[verify_fx]   断言 %d 条，失败 %d 条" % [_checks, _fails])
	if _fails == 0:
		print("[verify_fx] PASS")
		get_tree().quit(0)
	else:
		print("[verify_fx] FAIL")
		get_tree().quit(1)


func _case_projectile_field() -> void:
	_header("1. 弹道渲染（ProjectileField）")
	var session := BattleSession.new()
	session.setup(GameState.registry(), CommandBus)
	var shooter := session.spawn_unit("ou05", Vector3.ZERO, 0)
	var victim := session.spawn_unit("ou05", Vector3(0.0, 0.0, 600.0), 1)
	_expect(shooter != null and victim != null, "两艘单位生成成功")
	if shooter == null:
		session.shutdown()
		return

	var field := ProjectileField.new()
	add_child(field)
	await get_tree().process_frame   # 等 _ready 建好 MultiMesh
	field.bind_session(session)

	# 空场：不该渲染任何弹体
	field._process(0.016)
	_expect(field.rendered_count() == 0, "无弹体时渲染数 0（实际 %d）" % field.rendered_count())

	# 造三发弹：朝 +Z 飞（正好向着 victim）
	session.projectiles().spawn(Vector3.ZERO, Vector3(0, 0, 1), 2000.0, 100.0, 0, shooter.id, 0.8, 4.0)
	session.projectiles().spawn(Vector3(20, 0, 0), Vector3(0, 0, 1), 2000.0, 100.0, 0, shooter.id, 0.8, 4.0)
	session.projectiles().spawn(Vector3(-20, 0, 0), Vector3(0, 0, 1), 2000.0, 100.0, 1, 999, 0.8, 4.0)
	field._process(0.016)
	_info("  场上弹体 %d 发，渲染 %d 发" % [
		session.projectiles().active_count(), field.rendered_count()])
	_expect(field.rendered_count() == 3,
		"3 发弹都被渲染（实际 %d）" % field.rendered_count())
	_expect(field.multimesh != null and field.multimesh.instance_count == 3,
		"MultiMesh 实例数 = 3（实际 %d）" % (
			0 if field.multimesh == null else field.multimesh.instance_count))

	# 队色：前两发 team 0、第三发 team 1，颜色必须不同
	var c0 := field.rendered_color(0)
	var c1 := field.rendered_color(2)
	_expect(not c0.is_equal_approx(c1),
		"不同队伍弹道颜色不同（%s vs %s）" % [c0.to_html(false), c1.to_html(false)])

	# 位移方向正确：弹体朝 +Z 飞，写入的渲染方向必须等于飞行方向
	var p0: Projectile = session.projectiles().projectiles()[0]
	var rendered_dir := field.rendered_direction(0)
	_info("  弹体 0：direction=%s  渲染方向=%s" % [str(p0.direction()), str(rendered_dir)])
	_expect(rendered_dir.dot(p0.direction()) > 0.99,
		"弹道朝向跟随飞行方向（%s vs %s）" % [str(rendered_dir), str(p0.direction())])

	field.queue_free()
	session.shutdown()


func _case_death_burst() -> void:
	_header("2. 退场爆炸（DeathBurst）")
	var burst := DeathBurst.new()
	add_child(burst)
	burst.setup(Vector3(100.0, 0.0, 0.0), 32.0, Color(1.0, 0.5, 0.3))

	_expect(burst.is_playing(), "刚创建时正在播")
	_expect(burst.global_position.is_equal_approx(Vector3(100.0, 0.0, 0.0)),
		"落在指定位置（%s）" % str(burst.global_position))
	_expect(burst.get_child_count() > 0, "有可见网格子节点")

	var start_scale := burst.scale.x
	# 手动推进到中段（自动 _process 也在跑，这里只是保证走过关键帧）
	burst._process(DeathBurst.LIFETIME * 0.5)
	var mid_scale := burst.scale.x
	_info("  半径缩放：起始 %.1f → 中段 %.1f（舰体半径 32 m）" % [start_scale, mid_scale])
	_expect(mid_scale > start_scale, "爆炸在扩张（%.1f → %.1f）" % [start_scale, mid_scale])
	_expect(burst.is_playing(), "中段仍在播")

	# 推进到结束 → 应自行释放
	burst._process(DeathBurst.LIFETIME)
	_expect(not burst.is_playing(), "超过生命周期后不再播放")
	await get_tree().process_frame
	await get_tree().process_frame
	_expect(not is_instance_valid(burst) or burst.is_queued_for_deletion(),
		"到期后自行 queue_free")


func _header(text: String) -> void:
	print("[verify_fx] ---- %s" % text)


func _info(text: String) -> void:
	print("[verify_fx] %s" % text)


func _expect(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("[verify_fx]   PASS  %s" % what)
	else:
		_fails += 1
		print("[verify_fx]   FAIL  %s" % what)
