class_name PortraitCache
extends RefCounted

## 角色立绘的共享纹理缓存（S5 立绘迁移）。
##
## 为什么需要缓存：头顶徽章、左侧单位列表、右下详情面板都在**每帧**画头像。
## 每帧 `load()` 一次会反复读盘、并且每次生成新的资源实例 —— 这是典型的
## 表现层性能陷阱：单看不卡，单位一多就掉帧。
##
## 为什么放 static：三个 UI 类各自持有一份缓存等于同一张图被加载三遍，
## 而且某个类换关卡清缓存时其它类还留着旧图。缓存只有一份才不会出现这种分裂。
##
## 为什么不用 ResourceLoader 的全局缓存：Godot 确实会缓存已加载资源，
## 但 `load()` 对**缺失路径**每次都要走一次文件系统探测（失败不缓存），
## 而"这个单位没有立绘"恰恰是我们最需要快速返回的情况（要回退到机型缩写）。

## chara 编号 -> Texture2D（null = 查过但没有，缓存起来避免反复探测）
static var _textures: Dictionary = {}


## 解析并缓存某角色编号的立绘。没有（未登记 / 文件缺失）返回 null。
## 路径由注册表解析（assets.tbl 的 [face] 段），代码里不出现资源路径。
static func texture(chara: String) -> Texture2D:
	if chara.is_empty():
		return null
	# 角色编号恒为 3 位。TBL 把 `chara = 042` 当数字解会吃掉前导零，
	# 数据侧已经加了引号；这里再补一次零 —— 否则一处手改漏引号就会静默丢头像。
	var key := resolve_key(chara)
	if _textures.has(chara):
		return _textures[chara] as Texture2D

	var texture: Texture2D = null
	# GameState 是 autoload，全局作用域直接可用（不用 Engine.get_singleton：
	# autoload 不是引擎单例，那样取只会拿到 null，然后静默地退回“没有头像”）。
	var registry := GameState.registry()
	if registry != null:
		# 键名带 face_ 前缀：TBL 解析器不允许键名以数字开头
		var base := registry.asset("face_" + key)
		if not base.strip_edges().is_empty():
			# Registry.asset 返回不带扩展名的路径（与舰船模型同一口径）
			var path := base + ".png"
			if ResourceLoader.exists(path):
				texture = load(path) as Texture2D

	_textures[chara] = texture
	return texture


## 实际使用的键（验证用：确认补零逻辑生效）
## 注意 GDScript 的 String 没有 zfill（那是 Python 的），手写左补零。
static func resolve_key(chara: String) -> String:
	var key := chara.strip_edges()
	while key.length() < 3:
		key = "0" + key
	return key


## 是否解析到了立绘（验证用）
static func has(chara: String) -> bool:
	return texture(chara) != null


## 清空缓存（换关卡 / 换皮肤包时用）
static func clear() -> void:
	_textures.clear()
