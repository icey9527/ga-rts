# 里程碑进度

> 本文件是唯一的进度真值来源。每完成一个阶段更新一次，不写流水账。

## 当前状态

**S0 完成**（tag v0.0.1-s0 后续 tag v0.0.2-s0.1）—— 地基、文档基线、数据注册表设计、工具分层
**S0.5 进行中** —— 模型转换管线已跑通（29 个 glb / 25.9 MB / 4.8 秒），剩余天空烘焙、特效管线、base.tbl

## 阶段计划

| 阶段 | 目标 | 交付物 | 状态 |
| --- | --- | --- | --- |
| **S0** | 地基 | git 仓库、目录骨架、14 份 ADR、架构/尺度/操作/模型管线/数据注册表/工具分层文档、模型清单、Sylpheed 参考侦察 | ✅ 完成 |
| **S0.5** | 模型管线 | batch_obj2glb.py ✅、verify_glb.py ✅、天空烘焙、特效管线、manifest.json ✅、base.tbl 初版 | 进行中 |
| **S1** | 竖切片 | project.godot 配置（autoload + input map）、最小 main.tscn、焦点轨道相机 + 2D 正交相机、ViewProjection、1 艘船能绕障碍飞到指定点 | 未开始 |
| **S2** | 模拟闭环 | 状态机 / 索敌 / 开火 / 弹体 / 伤害 / 死亡，两军各 5 单位能打起来 | 未开始 |
| **S3** | 高度与编队 | 分层高度切换、编队阵型、单位间分离力、仿真精度分层 | 未开始 |
| **S4** | 内容迁移 | 15 机型全部数据化、地图、技能、AI 四层 | 未开始 |
| **S5** | 包壳 | 菜单 / 部署 / 对白 / 存档 / 音频 / 打包分发 | 未开始 |

## ADR 索引

| 编号 | 标题 |
| --- | --- |
| 0001 | 双视图模式：2D 平面 + 3D 空间 |
| 0002 | 相机：焦点轨道（禁止自由飞行） |
| 0003 | 模拟永远是 3D，高度采用分层而非自由空间 |
| 0004 | 寻路：XZ 平面可视图 + Dijkstra，不用 NavMesh |
| 0005 | 模型管线：OBJ → GLB，只用 a 档 SB/U |
| 0006 | 资源打包：可分 PCK + AssetCatalog 间接层 |
| 0007 | Git 工作流、文档组织、署名约定 |
| 0008 | 数据注册表：单一入口 base.tbl + 目录即 ID + 资产引用表 |
| 0009 | 单一 SB 模型 + 引擎自动 LOD（不需要多份高低模资源） |
| 0010 | 资源包用 .dat 后缀，可多包挂载 |
| 0011 | 工具与游戏主代码分离，临时脚本单独目录 |
| 0012 | 借鉴 Project Sylpheed 的引擎框架（不移植其战斗模型） |
| 0013 | 碰撞：三层碰撞体 + 扫掠弹体 + 命中走信号 |
| 0014 | 关卡编排：GDScript 协程 + 帧对比触发器 |

## S0 已完成

- [x] git 初始化（此前项目无版本控制）
- [x] 目录骨架 38 个（scenes / scripts / data / assets / docs / plans / tools / tests）
- [x] .gitignore（排除 .godot/、导出产物、原始素材库、.pi/）
- [x] docs/ARCHITECTURE.md 架构事实与六条硬规则
- [x] docs/scale-and-units.md 世界尺度写死（1 unit = 1 m，三层高度，相机参数，LOD 距离）
- [x] docs/controls.md 双视图操作映射
- [x] docs/model-pipeline.md 模型管线（含 2362 个 OBJ 的实测面数/材质统计）
- [x] docs/CONTRIBUTORS.md 署名约定
- [x] docs/adr/0001~0007 决策记录
- [x] tools/model-pipeline/inventory-scn1.csv 全量模型清单（575 个 obj 的顶点/面/材质数）
- [x] docs/data-registry.md 数据注册表与资产引用设计（问题总纲）
- [x] docs/tooling.md 工具与脚本分层规范
- [x] docs/adr/0008~0011 四份新决策记录
- [x] docs/adr/0012~0014 三份新决策记录（Sylpheed 引擎框架、碰撞与扫掠弹体、关卡编排）
- [x] 侦察 F:/sqrttt（Project Sylpheed 反汇编分析，356 文件 / 9.5 MB）并提炼可迁移设计
- [x] ARCHITECTURE.md 修订：八条硬规则、五核心接口、碰撞三层、累加器、请求结算、行为栈
- [x] 本地 Godot 4.7.2 API 文档导出（810 个 XML，用于校验 API 而非靠记忆）
- [x] .gitignore 新增 tools/temp/

## S0 环境确认

| 工具 | 状态 |
| --- | --- |
| Blender | ✅ 4.5.0 —— C:\Program Files\Blender Foundation\Blender 4.5\blender.exe |
| Godot | ✅ 4.7.2 —— F:\godot\Godot_v4.7.2-stable_win64.exe |
| Python / gcc / dotnet / git-lfs | ✅ 均可用 |
| 本地 Godot API 文档 | ✅ %TEMP%\godot-docs-4.7\doc\classes |

## S0 剩余（需 S1 骨架配合）

- [ ] project.godot 的 autoload 与 input map（依赖 S1 的脚本骨架，避免引用不存在的路径）
- [ ] 主场景 main.tscn（依赖 S1）
- [ ] `load_resource_pack` 对 .dat 后缀的冒烟测试（ADR-0010 待验证项）

## 下一步（S0.5 详细清单）

1. ~~安装 Blender~~ ✅ 4.5.0
2. ~~编写 tools/pipeline/model-pipeline/batch_obj2glb.py~~ ✅
   - 输入：F:/godot/model/el/scn1 下 a 档目录（b/c 档跳过）
   - 处理：部件归属过滤、合并非炮塔部件、pivot 归位、按贴图去重材质
   - 输出：assets/models/{ships,objects}/<id>/<id>.glb（无 LOD 变体）
   - 生成 tools/pipeline/model-pipeline/manifest.json ✅
   - **实测结果：29 个逻辑 ID / 25.9 MB / 17.7 万三角面 / 耗时 4.8 秒**
3. ~~编写 verify_glb.py 回读校验~~ ✅（层级、尺寸、炮塔 pivot��材质去重）
4. 天空球烘焙：ek/axo/stage/*/si_sbg_* → equirectangular 全景 → assets/sky/
5. 特效管线：el/scn0 下 oe* 与 ek/axo/effects/si_e* → 粒子/billboard 资源
6. 写 content/base.tbl + content/assets/assets.tbl 初版
7. **舰首朝向目视确认**（唯一未验证项）- 进 Godot 看一眼模型是否头朝 -Z
8. 用 Godot 打开验证：拖一艘进场景，检查尺寸、材质、自动 LOD 是否生效

## 管线已知问题与结论

| 项 | 结论 |
| --- | --- |
| 坐标 | OBJ Y上/-Z前 → Blender Z上 → glTF Y上/-Z前，导出后长轴正确落在 Z |
| 尺度 | 1:1 不缩放，原始单位≈米（无人机 8m / 护卫舰 63m / 主力 764m） |
| 材质 | 按贴图去重，单舰 6 槽 → 2 个（drawcall 降 3 倍） |
| 坑 1 | `mesh.materials.clear()` 会重置所有面材质索引，必须先缓存后写回（已修） |
| 坑 2 | `ob1505a/` 里混着 `SB_ou241E`（属于 ou241），已按 ID 归属剔除（已修） |
| 坑 3 | map_Ka 不被 Blender 支持，只剩警告，不影响结果 |

## 待用户拍板（不阻塞）

- 战争迷雾是否引入（原 2D 版无）
- 损伤分段模型（_crash_S0~S4）是否启用
- 小飞机是否走 MultiMesh 集群渲染
- TBL 的 `base` 继承机制是否现在就要（P2）
