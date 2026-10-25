# 模型管线（tools/pipeline/model-pipeline）

素材源（只读，**不入库**）：`F:/godot/model`
产物（入库）：`assets/models/**/*.glb`
本目录（入库）：脚本 + 清单

> 依据：ADR-0005 模型管线、ADR-0009 单一 SB 自动 LOD、ADR-0011 工具与游戏代码分离

## 脚本

| 文件 | 作用 | 状态 |
| --- | --- | --- |
| `batch_obj2glb.py` | OBJ → GLB 批量转换（Blender headless） | ✅ 可用，已跑通 29 个模型 |
| `verify_glb.py` | 回读校验：层级 / 尺寸 / 材质去重 / 炮塔 pivot | ✅ 可用 |
| `render_preview.py` | 正交预览渲染，用于目视确认舰首朝向 | ✅ 可用 |
| `inventory-scn1.csv` | 全量 OBJ 统计（顶点/面/材质），生成物，已 gitignore | ✅ |
| `manifest.json` | 逻辑 ID → 尺寸 / 面数 / 材质 / 炮塔节点，供 AssetCatalog 用 | ✅ 自动生成 |

## 用法

转换全部：

```
"C:\Program Files\Blender Foundation\Blender 4.5\blender.exe" -b -P tools/pipeline/model-pipeline/batch_obj2glb.py
```

只转指定模型（冒烟测试）：

```
blender.exe -b -P batch_obj2glb.py -- --only ou05,ou134
```

只测量不写文件：

```
blender.exe -b -P batch_obj2glb.py -- --no-export
```

回读校验：

```
blender.exe -b -P verify_glb.py -- assets/models/ships/ou05/ou05.glb
```

舰首方向（实测结论）：**素材舰首在 +Z，必须翻转 180° 到 -Z**。
脚本**默认已开启翻转**，无需额外参数。只在你确定判断错时才用：

```
blender.exe -b -P batch_obj2glb.py -- --no-flip
```

## 坐标推导（改之前必须先读懂）

```
素材 OBJ   Y 上、-Z 前      （Blender OBJ 导入器默认声明）
   ↓ 导入（默认轴）
Blender    Z 上、-Y 前
   ↓ 导出（export_yup=True）
glTF/Godot Y 上、-Z 前      ← Godot 前向就是 -Z
```

所以素材里 **+Z 若为舰首，导出后舰首正好在 Godot 的 -Z**，符合惯例。
校验脚本报告的是转换后的 Godot 尺寸（X 宽 / Y 高 / Z 前后）。

> ✅ 已实测确认：素材舰首在 +Z，引擎喷口在 -Z。翻转 180° 后在 `side_x` 视角
> （相机在 +X、屏幕右方 = -Z）下舰首朝屏幕右侧，与 Godot 前向 -Z 一致。
> 依赖脚本默认翻转（加 `--no-flip` 才会关闭）。

## 尺度

**1:1，不做任何缩放。** 实测素材尺度合理，原始单位≈米：

| 类别 | 实测跨度 |
| --- | --- |
| 无人机 ou09 / ou07 | 8.2 / 11.2 |
| 护卫舰 ou05 / ou107 | 63.6 / 60.6 |
| 中型 ou134 / ou137 | 351.7 / 200.9 |
| 主力 ou241 / ou242 / ou01 | 1123.5 / 811.8 / 764.5 |
| 大型物体 ob1501 / ob1504 | 6508 / 9836~12555 |

若个别单位需要游戏内缩放，写 `UnitDef.scale`，**不改模型文件**。

## 筛选规则

- 只扫 `el/scn1` 下 **a 档**目录（`ouXXa` / `obXXXXa`），b / c 档一律跳过
- 只取 `SB_*.obj`
- **部件必须属于本逻辑 ID**：`ob1505a/` 里混着 `SB_ou241E`，属于 ou241，会被剔除
- 炮塔类部件（cannon / aag / laser / missile / pod / drill）保持独立节点并做 pivot 归位
- 其余部件合并成单个 `body` 节点

## 材质处理

导入器会按 MTL 生成大量重复材质槽（例如 `SB_ou05E_body` 有 6 个槽，实际只有 2 张贴图）。
管线按**贴图名去重**重建材质：

| 素材贴图 | 接到 |
| --- | --- |
| `<stem>.png` | Base Color |
| `<stem>_lum.png` | Emission |
| `<stem>_bmp.png` | Normal Map（Non-Color） |
| `<stem>_ref.png` | 有则 Metallic 0.45，否则 0.05 |

实测效果：单舰材质 6 → 2，drawcall 直接降 3 倍。

> ⚠️ 已知坑：Blender 的 `mesh.materials.clear()` 会把所有多边形的材质索引**重置为 0**。
> 必须先缓存每个面的新索引，清空重建后再写回，否则所有面挤到 0 号材质，静默丢贴图。

## 首次全量结果（S0.5）

| 项 | 结果 |
| --- | --- |
| 逻辑 ID | 29 个（31 个 SB 文件，其中 2 个被归属过滤剔除） |
| 产物 | 25.9 MB / 29 个 glb |
| 耗时 | 4.8 秒 |
| 三角面合计 | 约 17.7 万 |
| 炮塔独立节点 | ou05 的 `turret_SB_ou05E_laser`（pivot 校验通过，偏差 0） |

## 待办

- [x] 舰首朝向确认（渲染图 + Godot 目测双重验证，脚本默认翻转）
- [ ] 特效管线 `oe*` / `si_e*`（单独脚本，走粒子/billboard 而非网格）
- [ ] 天空球烘焙 `bake_sky.py`（`ek/axo/stage/*/si_sbg_*` → equirectangular 全景）
- [ ] 武器挂点：模型里没有空节点，炮口位置需按武器类型在资源表里配偏移
