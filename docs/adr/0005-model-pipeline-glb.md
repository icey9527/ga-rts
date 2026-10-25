# ADR-0005 模型管线：OBJ → GLB，只用 a 档 SB/U

- 状态：已采纳
- 日期：S0

## 背景

素材源 F:/godot/model 有 2362 个 OBJ + 2362 个 MTL + 3822 个 PNG，共 0.35 GB。
Godot 4 能直接 import OBJ，但 2362 个独立导入项会让 .godot 缓存臃肿，且部件拼装、炮塔 pivot、
材质映射全部要运行时处理。

用户明确要求：只用 a 档（精度最高），c 档"最糊，绝对不用"。

## 实测数据（scn1 全量，S0）

| 档 | 文件数 | 面合计 |
| --- | --- | --- |
| a | 161 | 257,683 |
| b | 137 | 59,278 |
| c | 101 | 14,480 |

SB 模型池 31 个文件：面数最小 144 / 中位 5,138 / 最大 14,378；材质数 1~11，中位 6。

## 性能结论

**面数不是瓶颈**。580 (8G) + i5-9100F 同屏 150 艘 SB 约 77 万面，完全可行。

**drawcall 才是瓶颈**：单舰 6 材质 → 6 drawcall → 加阴影 pass ×2 = 12；150 艘 = 1800。
9100F 只有 4 核 4 线程，主线程提交是硬限制。

所以"全用 SB"没问题，但必须同时做材质合并与 LOD。

## 结论

1. **档位**：LOD0 = SB（a 档），LOD1 = a 档内的 U，LOD2 = billboard，极远 = UI 图标。
   **b / c 档不使用**。a 档内若无 SB（ou20a/ou21a/ou22a），该 U 直接当 LOD0。
2. **格式**：一次性批量转为 GLB，一艘船 1 个 glb，部件保留为子节点。
3. **工具**：Blender headless（`blender -b -P batch_obj2glb.py`）。本机暂无 Blender，需手动安装。
4. **入库**：原始素材库 F:/godot/model 不进仓库（.gitignore /model/）；转换产物 assets/models/**/*.glb 入库。
5. **目录约定**：assets/models/ships/<ounitid>/<ounitid>_lod0.glb

## 必须解决的三件事

1. **炮塔 pivot**：cannon / aag / missileA 是独立部件，必须把旋转轴心移到部件自身包围盒中心，
   否则运行时炮塔绕整船原点甩。管线里算，不留到运行时。
2. **朝向统一**：机头一律朝 -Z（Godot 前方）。不统一的话所有飞行手感调试都会变成灾难。
3. **材质映射**：_0 → Base Color，_0_lum → Emission，_0_bmp → Normal，_0_ref → Metallic/Roughness 参考值。

## 代价

- 需要安装 Blender（一次性成本）
- 转换后的 glb 会重新生成资产，改动素材源后需重跑管线（因此管线必须脚本化、幂等）

## 影响

docs/model-pipeline.md、tools/model-pipeline/、assets/models/
