extends Node

## 数据注册表验证场景（开发期工具，不属于游戏主流程）。
##
## 作用：构造 Registry、加载 content/、打印报告摘要与全部错误、抽样解析 3 个资产。
## 有错误时以退出码 1 结束，方便脚本判断。
##
## 运行：
##     Godot_v4.7.2-stable_win64_console.exe --path F:/godot/ga-rts \
##         scenes/dev/verify_registry.tscn
##
## 产物：
##     user://registry_report.txt（Registry 自己写）

## 抽样展示的资产逻辑名（逻辑名不是路径，硬编码在这里只是为了看输出）
const SAMPLE_ASSETS: Array[String] = ["ou05", "ob1501", "si_sbg_0110"]
## 抽样展示的单位 ID，空字符串表示跳过
const SAMPLE_UNIT := "ou05"


func _ready() -> void:
	var registry := Registry.new()
	var ok := registry.load_all()

	print("[verify_registry] 入口        : %s" % Registry.BASE_TBL)
	print("[verify_registry] 报告文件    : %s" % registry.report_file())
	print("[verify_registry] 单位数      : %d" % registry.units().size())
	print("[verify_registry] 资产数      : %d" % registry.asset_names().size())
	print("[verify_registry] 错误数      : %d" % registry.errors.size())
	print("[verify_registry] 警告数      : %d" % registry.warnings.size())
	print("[verify_registry] 结果        : %s" % ("PASS" if ok else "FAIL"))
	print("[verify_registry] 单位 ID     : %s" % ", ".join(registry.units()))
	print("[verify_registry] 类别 ID 数  : units=%d teams=%d maps=%d" % [
		registry.ids_of("units").size(),
		registry.ids_of("teams").size(),
		registry.ids_of("maps").size()])

	print("[verify_registry] ---- 资产抽样 ----")
	for logical in SAMPLE_ASSETS:
		print("[verify_registry]   %-12s -> '%s'" % [logical, registry.asset(logical)])

	if not SAMPLE_UNIT.is_empty():
		var data := registry.unit(SAMPLE_UNIT)
		var stats: Dictionary = data.get("stats", {})
		print("[verify_registry] ---- 单位抽样 %s ----" % SAMPLE_UNIT)
		print("[verify_registry]   source : %s" % str(data.get("source", "")))
		print("[verify_registry]   name   : %s" % str(stats.get("name", "")))
		print("[verify_registry]   speed  : %s  type=%s" % [
			str(stats.get("speed", "")), type_string(typeof(stats.get("speed", null)))])
		print("[verify_registry]   max_hp : %s" % str(stats.get("max_hp", "")))
		print("[verify_registry]   model  : %s" % str((data.get("assets", {}) as Dictionary).get("model", "")))

	print("[verify_registry] ---- 警告逐条 ----")
	if registry.warnings.is_empty():
		print("[verify_registry]   (无)")
	for i in registry.warnings.size():
		print("[verify_registry]   %d) %s" % [i + 1, registry.warnings[i]])

	print("[verify_registry] ---- 错误逐条 ----")
	if registry.errors.is_empty():
		print("[verify_registry]   (无)")
	for i in registry.errors.size():
		print("[verify_registry]   %d) %s" % [i + 1, registry.errors[i]])

	if not ok:
		print("[verify_registry] 校验未通过，退出码 1")
		get_tree().quit(1)
		return
	print("[verify_registry] 校验通过，退出码 0")
	get_tree().quit(0)
