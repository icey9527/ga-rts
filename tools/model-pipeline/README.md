# 模型管线工具

素材源（只读，不入库）：**F:/godot/model**
产物（入库）：assets/models/**/*.glb
本目录（入库）：脚本 + 清单

## 文件

| 文件 | 说明 | 状态 |
| --- | --- | --- |
| inventory-scn1.csv | scn1 全量 575 个 OBJ 的顶点/面/组/材质/体积统计（生成物，已 gitignore） | 已生成 |
| inventory-manifest.json | 按逻辑 ID 归组的清单，供管线与 AssetCatalog 使用 | 待生成 |
| batch_obj2glb.py | Blender headless 批处理：OBJ → GLB | 待写（需先装 Blender） |
| bake_sky.py | 天空球 → equirectangular 全景烘焙 | 待写 |
| scan_inventory.ps1 | 重新生成 inventory（幂等） | 待写 |

## 前置依赖

- Blender LTS（**本机未安装**，需手动下载 https://www.blender.org/download/）
- Godot 4.7（已有：F:/godot/Godot_v4.7.2-stable_win64.exe）
- 无需其他工具；node / git-lfs 已就绪备用

## 筛选规则（已定，见 ADR-0005）

- 只取 `el/scn1` 下 **a 档**目录（`ouXXa` / `obXXXXa`）
- 只取 `SB_*`（LOD0）与 `*U*`（LOD1）模型
- **b / c 档一律跳过**
- 跳过 `ball/bounding`（包围球，非可见）、`compass_*`（HUD 用，单独处理）
- 特效（oe / si_e*）与天空（si_sbg）走独立管线，不与舰船混

## 目录映射

```
F:/godot/model/el/scn1/ou134a/SB_ou134E_body/SB_ou134E_body.obj
        └─► assets/models/ships/ou134/ou134_lod0.glb

F:/godot/model/el/scn1/ou134a/ou134U_body/ou134U_body.obj
        └─► assets/models/ships/ou134/ou134_lod1.glb

F:/godot/model/el/scn1/ob1501a/SB_ob1501A/SB_ob1501A.obj
        └─► assets/models/objects/ob1501/ob1501_lod0.glb
```

## 命名规范（产物）

- 逻辑 ID 全部小写：`ou134` / `ob1501`
- 一个逻辑 ID 一个目录
- LOD 后缀 `_lod0`（SB）/ `_lod1`（U）
- 部件作为子节点保留原名（`body` / `cannon` / `aag` / `missileA` / `laser` / `hou`）
- 炮塔类部件的 pivot 移到自身包围盒中心，命名前缀 `turret_`

## 炮塔 pivot 识别规则

已知炮塔类部件后缀：`cannon` / `aag`（防空炮） / `laser` / `missileA` / `pod` / `drill`

处理：部件导入后，把 mesh 原点移到该部件自身包围盒中心，再放回世界位置的相对偏移。
这样运行时 `turret.look_at(target)` 才能正确旋转。
**这是最容易翻车的点，必须在这一层解决，不要留到运行时。**

## 材质映射

| 原始 | Godot |
| --- | --- |
| _0.png | Base Color（sRGB） |
| _0_lum.png | Emission |
| _0_bmp.png | Normal Map |
| _0_ref.png | Metallic / Roughness 参考 |
| .agi.png 后缀 | 重命名为 .png |
| 缺失的 PBR 贴图 | 统一默认值 metallic 0.2 / roughness 0.7 |

## 金额与预算约束

- 原始素材库 0.35 GB **不进仓库**
- 转换产物只保留用到的模型（预计 30~50 艘舰 + 20 个物体 + 特效），预计 30~80 MB，可直接入库
