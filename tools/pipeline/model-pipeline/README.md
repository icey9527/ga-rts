# 模型管线（tools/pipeline/model-pipeline）

素材源（只读，**不入库**）：`F:/godot/model`
产物（入库）：`assets/models/**/*.glb`
本目录（入库）：脚本 + 清单

> 依据：ADR-0005 模型管线、ADR-0009 单一 SB 自动 LOD、ADR-0011 工具与游戏代码分离

## 脚本

| 文件 | 作用 | 状态 |
| --- | --- | --- |
| `batch_obj2glb.py` | OBJ → GLB 批量转换（Blender headless） | ✅ 可用，已跑通 29 个模型 |
| `batch_effects.py` | 特效公告板 OBJ → GLB（自发光 + 亮度 alpha） | ✅ 可用，已跑通 208 个特效 |
| `verify_glb.py` | 回读校验：层级 / 尺寸 / 材质去重 / 炮塔 pivot | ✅ 可用 |
| `render_preview.py` | 正交预览渲染，用于目视确认舰首朝向 | ✅ 可用 |
| `inventory-scn1.csv` | 全量 OBJ 统计（顶点/面/材质），生成物，已 gitignore | ✅ |
| `manifest.json` | 逻辑 ID → 尺寸 / 面数 / 材质 / 炮塔节点，供 AssetCatalog 用 | ✅ 自动生成 |
| `effects_manifest.json` | 特效逻辑 ID → 层数 / 面数 / 材质 / 贴图 / alpha 统计 / 字节数 | ✅ 自动生成 |

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

## 特效管线（batch_effects.py）

把 `oe*` / `si_*` 特效素材转成 GLB，产物进 `assets/models/effects/<id>/<id>.glb`，
并在 `content/assets/assets.tbl` 的 `[vfx]` 节按逻辑 ID 登记。

```
blender.exe -b -P batch_effects.py                       # 全量（默认两处素材根）
blender.exe -b -P batch_effects.py -- --only oe0350a,si_eah_0130   # 冒烟
blender.exe -b -P batch_effects.py -- --limit 5 --no-export        # 只测量不写文件
blender.exe -b -P batch_effects.py -- --width 128                  # 贴图上限改 128
```

选项：`--src`（可重复，默认 `F:/godot/model/el/scn0` + `F:/godot/model/ek/axo/effects`）、
`--dst`、`--only`、`--limit`、`--width`（默认 256）、`--tex-dir`、`--manifest`、`--no-export`。

### 素材实情（实测）

| 项 | 数据 |
| --- | --- |
| 逻辑 ID | 208 个（`el/scn0` 77 个 `oe*`，`ek/axo/effects` 131 个 `si_*`），**目录名就是逻辑 ID** |
| OBJ 文件 | 271 个 —— 一个 ID 可能有 1~12 个子层目录，每个 1 个 obj |
| 体积 | 素材源 7.5 MB / 产物 6.5 MB |
| 几何 | 2~2377 三角面，中位 **14** 个；绝大多数是纯四边形面片（一个 ID 拆 1~15 层） |
| 材质 | 每个 `usemtl` 一张贴图；一个特效 1~8 个材质（`si_eos_1000` 最多 8） |
| 贴图 | 460 张 PNG，**全部 RGB 无 alpha**，最大边 256（128² 占多数，也有 64×128 / 256×64 这类非方形） |

两种目录布局都要支持，`find_obj_files()` 会先看根目录再看一层子目录：

```
el/scn0/oe821a01/oe821U_00/oe821U_00.obj        ← 子层目录，一个 ID 最多 12 个
ek/axo/effects/si_eah_0130/si_eah_0130.obj      ← 平铺
```

### 为什么按公告板处理

这些是**贴图公告板**，不是实体模型：一个特效 = 若干四边形，每层贴一张图（95 顶点 / 125 面 / 1 材质
或 24 顶点 / 12 面 / 4 材质）。所以本脚本**刻意不做**舰船管线里那些事：

| 舰船管线做的事 | 特效管线 | 原因 |
| --- | --- | --- |
| 合并部件成单个 `body` | **不合并**，每层一个 `layer_NN_<贴图>` 节点 | 一层就是一次叠加绘制，合并等于把不同贴图糊成一张 |
| 材质按贴图去重合并 | 只在**同一 mesh 内**去重重复槽位 | 不同贴图不能共用一个材质 |
| 炮塔 pivot 归位 | 不做 | 没有可动件 |
| 舰首翻转 180° | **不翻转** | 特效没有方向概念 |
| 尺寸归一化 | 不做（1:1） | 尺度就是原引擎尺度 |
| 导入轴 `NEGATIVE_Z` / `Y` | **完全一样** | 保住与舰船一致的轴系，日后挂到船上不错位 |

### 透明度怎么来的

源图无 alpha、原引擎用**加法混合**（黑色 = 透明）。管线两头都铺好，保证 Godot 端不管走哪条路都合理：

1. **材质改自发光**：`Base Color ← 贴图` + `Emission Color ← 同一张贴图`（Emission Strength 1.0）。
2. **导出后补 GLB 的 JSON**：`baseColorFactor = [0,0,0,1]`（RGB 乘 0 → 彻底关掉漫反射，
   只剩发光；黑的地方不发光，等价加法混合）、`emissiveFactor = [1,1,1]`、
   `baseColorTexture = emissiveTexture = 同一张贴图`、`alphaMode = BLEND`、`doubleSided = true`。
3. **贴图 alpha = 亮度**：读像素前把 colorspace 设成 `Non-Color`（不做任何色彩空间转换，
   读到的就是文件里的原始 sRGB 数值），算 Rec.709 亮度 `0.2126R + 0.7152G + 0.0722B`
   写进 alpha 通道（255 = 不透明），RGB 原样保留。中间图落到 `.effects_tex/`（已 gitignore），
   最终**内嵌进 GLB**，`assets/` 下不落散图。

于是 Godot 侧拿到的是：`StandardMaterial3D`，albedo 黑色 + albedo 贴图（只为提供 alpha）+
emission 贴图，transparency = alpha。想要更接近原引擎，把材质的 blend mode 换成
`BaseMaterial3D.BLEND_MODE_ADD` 即可，不需要改资源。

> 为什么必须补 JSON：Blender 导出器没法表达「baseColorTexture 提供 alpha，但 RGB 要乘 0」——
> 它只会写 `baseColorFactor = [1,1,1,1]`，那样漫反射会把特效渲染成一张白板。
> 补丁还顺手合并了导出器为 baseColor / emissive 重复生成的 texture 条目（每张图从 2 个降到 1 个）。

### 首次全量结果（T-0.5.1）

| 项 | 结果 |
| --- | --- |
| 成功 / 目标 | 208 / 208（0 失败） |
| 产物 | 6.49 MB / 208 个 glb |
| 耗时 | 20.5 秒（冷跑，含 460 张贴图的亮度 alpha 生成；贴图缓存命中后约 17 秒） |
| 三角面合计 | 18,524 |
| 材质 / 贴图 | 398 / 397（`si_eos_3000` 有一个 `GEOM_0_mat0` 没有 `map_Kd`，见下） |
| 节点 | 每层一个 `layer_NN_<贴图名>` 子节点（1~15 层）+ 一个与 ID 同名的根空节点 |

### 已知限制

1. **没有方向概念，也没有朝向约定**。清单里 `size_m` 只说明包围盒，比如 `si_eah_0130` 是
   300×0×300 的水平面片。运行时谁用谁负责旋转（粒子/公告板系统按相机朝向摆）。
2. **尺度不统一，跨度极大**：`oe0350a` 20×58×15，`si_hex_1102` 82741×79044。后者是关卡级
   网格特效，必须靠 `UnitDef.scale` / 节点缩放压下来，**不改模型文件**。
3. **无贴图材质被置成完全透明**（alpha 0）。素材里确实有材质不带 `map_Kd`
   （`si_eos_3000_GEOM_0_mat0`），加法混合下「无贴图 = 纯黑 = 什么都不加」，所以让它不可见
   才忠实；如果日后发现它其实该是实体暗面，需要单独处理。
4. **`--width` 只缩不放**。源图最大边 256，默认值等于不缩放；缩到 128 会损失 `si_hex_*`
   这类大网格特效的细节。
5. **alpha = 亮度是近似**。原引擎的加法混合强度参数已不可考（同天空球的结论），
   亮度当 alpha 在「不做加法混合」时最自然，但半透区的观感可能和原版有差异。
6. **产物不含动画**。素材里没有逐帧序列（每个 ID 只有一张静态图），要做序列帧得靠材质 UV 滚动
   或引擎侧多张贴图切换，本管线不管。

## 天空球烘焙（bake_sky.py）

把半径约 5 万单位的天空球壳烘成 equirectangular 全景，运行时交给 Godot 的 Sky 资源。
产物：`assets/sky/<si_sbg_XXXX>.png`（2048×1024）+ `sky_manifest.json`。

原始素材：25 个关卡目录，去重后 **15 套不重复天空**；每套由 4~14 个 GEOM 球壳拼成，
贴图全是 256² 以内的 RGB（无 alpha），图层包括星空底 si_sbg / 星云 si_sbs /
云 si_sbo / 轨道环 si_sor / 太阳 si_sun / 环境底色 si_abg。

### 三个关键坑（都已修，勿重蹈）

1. **材质必须接到 Material Output**。只把贴图连到 BSDF 的 Emission Color 而漏掉
   `BSDF -> Material Output`，节点树没有输出，渲染结果永远是纯黑，且不报错。
   换引擎、改裁剪、加曝光都救不回来 —— 本末症状就这一个。
2. **不能用 AgX 色调映射**。必须 `view_transform = 'Standard'`，否则纯白 1.0 被压到 0.75，
   所有颜色错位。
3. **隐藏对象要遍历全部网格**，不能只遍历参与叠加的层。被跳过的 `si_abg`（16×16 纯白）
   如果留着可见，会把它里面所有层全部遮挡。

### 混合方式

原引擎的混合参数已不可考。实测 **纯加法会严重过曝**（峰值到 3.5），改用 **screen**
（`1-(1-a)(1-b)`，加法但永不溢出），默认已选它。可切回对比：

```
blender.exe -b -P bake_sky.py -- --blend sum    # 过曝，仅调试用
blender.exe -b -P bake_sky.py -- --blend max    # 取最亮，星空更干净
```

### 已选择跳过 `si_abg`

16×16 纯白图层（平均色 1,1,1），原意应是环境底色/雾色，需要乘以关卡配置的低强度才合理。
我们没有那份配置，直接跳过，否则整今天空变灰白。

## 待办

- [x] 舰首朝向确认（渲染图 + Godot 目测双重验证，脚本默认翻转）
- [x] 特效管线 `batch_effects.py`（208 个 `oe*` / `si_*` → 6.49 MB glb，耗时 20.5 秒）
- [x] 天空球烘焙 `bake_sky.py`（15 套天空 → 2048×1024 equirect，共 26.2 MB，耗时 556 秒）
- [ ] 武器挂点：模型里没有空节点，炮口位置需按武器类型在资源表里配偏移
