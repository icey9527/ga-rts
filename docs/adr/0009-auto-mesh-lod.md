# ADR-0009 单一 SB 模型 + 引擎自动 LOD（不需要多份高低模资源）

- 状态：已采纳
- 日期：S0
- 部分取代：ADR-0005 里的"LOD0=SB / LOD1=a 档 U"结论

## 背景

ADR-0005 原本计划 LOD0 用 SB、LOD1 用 a 档内的 U 模型，即需要维护两套资源文件。

用户明确反对："我更想全部用 SB，或者说你在代码实现智能退化，而不是通过硬切换高模低模，
不然的话要放几组不同的高模低模资源，不太好维护。"

## 查证（本机 Godot 4.7.2 --doctool 导出的官方类文档）

| 事实 | 证据 |
| --- | --- |
| OBJ 导入自动生成 LOD，默认开启 | ResourceImporterOBJ.xml: `<member name="generate_lods" ... default="true">` |
| 场景导入自动生成 LOD，默认开启 | ResourceImporterScene.xml: `meshes/generate_lods` default="true" |
| 运行时全局 LOD 偏置 | Viewport.xml: `mesh_lod_threshold` (float, default 1.0，越大越激进) |
| 按距离剔除与淡入 | GeometryInstance3D.xml: `visibility_range_begin/end/fade_mode` |
| 同时存在逐实例偏置 | GeometryInstance3D.xml: `lod_bias` (default 1.0) |

## 结论

**只导入 SB 一份资源。不产出 U/M/L 变体。**

- 导入时 Godot 自动生成 4 级 mesh LOD（默认已开）
- 全局质量由 Viewport.mesh_lod_threshold 调（远距离掉帧就往上调）
- 距离剔除与淡出用 geometry instance 的 visibility_range 配置
- 极远（> 8 km）用 billboard，再远用 UI 图标（这两级是表现层，不占模型资源）
- 个别模型自动简化效果差（细长部件、对称结构），用逐实例 lod_bias 或手工 LOD 覆盖，不回到多套资源

## 管线影响

- batch_obj2glb.py 只处理 SB_ 模型
- 但要注意：一个 glb 里若含多个 mesh 子节点，每个 mesh 独立生成 LOD，各部件消失时机不一致
  → 因此管线里**按材质合并成 1~2 个 surface 再导出**，LOD 一致性最好，顺带压 drawcall
- 炮塔等需要独立旋转的部件**必须保持独立 mesh**，接受它各自的 LOD 时机（炮塔本身小，影响可忽略）

## 代价

- 自动 LOD 的简化质量不如手工制作的低模，远景可能出现形状崩坏（细长天线、镂空结构）
- 首次导入会多花时间（生成 LOD 与阴影 mesh）
- .godot 缓存会变大

## 影响

docs/model-pipeline.md、docs/scale-and-units.md 的 LOD 段、tools/pipeline/model-pipeline/
