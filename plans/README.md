# 里程碑进度

> 本文件是唯一的进度真值来源。每完成一个阶段更新一次，不写流水账。

## 当前状态

**S0 进行中** —— 地基与文档基线

## 阶段计划

| 阶段 | 目标 | 交付物 | 状态 |
| --- | --- | --- | --- |
| **S0** | 地基 | git 仓库、目录骨架、7 份 ADR、架构/尺度/操作/模型管线文档、模型清单 | 进行中 |
| **S0.5** | 模型管线 | 装 Blender、batch_obj2glb.py、manifest.json、炮塔 pivot 归位、天空球烘焙 | 未开始 |
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

## S0 未完成（阻塞在外部依赖）

- [ ] 安装 Blender（本机未装，需手动下载安装包）
- [ ] project.godot 的 autoload 与 input map（依赖 S1 的脚本骨架，避免引用不存在的路径）
- [ ] 主场景 main.tscn（依赖 S1）

## 下一步（S0.5 详细清单）

1. 安装 Blender（用户手动下载 LTS 版）
2. 编写 tools/model-pipeline/batch_obj2glb.py：
   - 输入：F:/godot/model/el/scn1 下 a 档目录 + 选定 ob + 选定 oe
   - 处理：合并部件、pivot 归位、朝向统一 -Z、材质映射、LOD 分组
   - 输出：assets/models/{ships,objects,effects}/<id>/<id>_lod{0,1}.glb
   - 生成 tools/model-pipeline/manifest.json
3. 天空球烘焙：ek/axo/stage/*/si_sbg_* → equirectangular 全景 → assets/sky/
4. 用 Godot 打开验证：随便拖一艘进场景，检查朝向、尺寸、材质、pivot

## 待用户拍板（不阻塞 S0）

- 战争迷雾是否引入（原 2D 版无）
- 损伤分段模型（_crash_S0~S4）是否启用
- 小飞机是否走 MultiMesh 集群渲染
