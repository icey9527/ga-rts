# 工具与脚本分层

> 铁律：**游戏主代码（scripts/）绝不加载 tools/ 下的任何东西。**
> tools/ 只被开发者手动运行，或由 CI 运行。

## 目录

```
tools/
├─ pipeline/          长期管线工具，入 git，幂等，可重跑
│  └─ model-pipeline/   OBJ → GLB、天空烘焙、模型清单
├─ dev/               长期开发辅助，入 git
│  ├─ balance/          数值模拟与平衡报告
│  └─ debug/            运行时调试面板/探针
├─ ci/                自动检查，入 git，CI 与本地共用
│  ├─ check_tbl.gd /      TBL 语法与引用完整性校验
│  ├─ check_gdscript.ps1  GDScript 编译检查
│  └─ run_tests.ps1       gdUnit4
└─ temp/              临时脚本，gitignore，随手删
```

## 三类脚本的判定标准

| 类型 | 放哪 | 入 git | 判定 |
| --- | --- | --- | --- |
| **长期工具** | tools/pipeline 或 tools/dev | 是 | 会重复跑；别人也要跑；坏了影响产出 |
| **CI 检查** | tools/ci | 是 | 每次改动都该跑；失败要拦住提交 |
| **临时脚本** | tools/temp | **否** | 一次性；只为本机；跑完就扔 |

判定口诀：**"这个脚本明年还会有人跑吗？"** 会 → pipeline/dev；不会 → temp。

## 长期工具的准入条件（缺一条就不算长期工具）

1. 有 README：输入是什么、输出到哪、依赖什么、跑一次多久
2. **幂等**：跑两次结果一样，不产生重复产物
3. **失败要炸**：不静默跳过错误文件，出错就非零退出并打印失败清单
4. 不依赖本机绝对路径，路径从配置文件或参数传入（默认值可以写在 README 里）
5. 产物落在明确的输出目录，能整目录删除重建

## 临时脚本规矩

- 一律放 `tools/temp/`，该目录已在 .gitignore
- 允许硬编码路径、允许写死文件名、允许粗糙
- **不允许**被 scripts/ 引用
- **不允许**产出物留在 assets/ / data/ 里 —— 要留下的东西，转成长期工具重跑一遍再落盘
- 跑完任务就删；忘了删也不影响仓库（因为不入库）

## pipeline 工具的当前清单

| 工具 | 输入 | 输出 | 状态 |
| --- | --- | --- | --- |
| model-pipeline/batch_obj2glb.py | F:/godot/model/el/scn1 a 档目录 | assets/models/**/*.glb | 待写（Blender 4.5 已就位） |
| model-pipeline/bake_sky.py | ek/axo/stage/*/si_sbg_* | assets/sky/*.exr | 待写 |
| model-pipeline/scan_inventory.ps1 | F:/godot/model/el/scn1 | tools/model-pipeline/inventory-*.csv | 待写（当前脚本是临时跑的） |

## 环境

| 工具 | 版本 / 路径 |
| --- | --- |
| Blender | 4.5.0 —— C:\Program Files\Blender Foundation\Blender 4.5\blender.exe |
| Godot | 4.7.2 —— F:\godot\Godot_v4.7.2-stable_win64.exe |
| Godot 控制台版 | F:\godot\Godot_v4.7.2-stable_win64_console.exe |
| Python | 已装（pi 工具链 shim） |
| gcc | C:\TDM-GCC-32\bin\gcc.exe |
| dotnet | C:\Program Files\dotnet\dotnet.exe |
| git-lfs | 3.7.1 |
| 本地 Godot API 文档 | %TEMP%\godot-docs-4.7\doc\classes（由 --doctool 导出，810 个 XML，查 API 用它，别靠记忆） |

## 重新导出本地 Godot 文档

```
Godot_v4.7.2-stable_win64_console.exe --doctool <输出目录> --headless
```

产物：<输出目录>/doc/classes/<ClassName>.xml（注意是大驼峰文件名，不是小写）。
查 API 时用这个，比联网查更准——它就是本机这个版本编译进去的真值。
