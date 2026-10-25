# 模型管线

> 素材源：F:/godot/model（只读，**不入库**）
> 产物：assets/models/**/*.glb（入库）
> 脚本：tools/model-pipeline/（入库，必须可复现）

## 一、素材源实际结构

```
F:/godot/model/
├─ ek/axo/                      关卡演出资源（按关卡号）
│  ├─ effects/   si_eah/si_eeb/si_eos… ~130 个特效模型
│  ├─ machines/  mes_XXXX + si_mon/moo/mos（炮台、移动体）
│  ├─ ompaths/   si_cam_0100~0700（相机路径，5 个）
│  └─ stage/000200…130600/       24 个关卡背景（si_sbg 天空球 / si_grd 地面 / si_sbf / si_sor）
└─ el/
   ├─ scn0/                     76 个纯 oe 特效
   └─ scn1/                     主战场：ou 舰船 + ob 物体 + oe 特效 + compass + ball + testbg
```

规模：8557 文件 / 0.35 GB（3822 png = 250 MB，2362 obj = 104 MB，2362 mtl = 0.8 MB）。
格式：Wavefront OBJ + MTL + PNG，无 dds/tga，无配置文本。

## 二、命名规律（解析规则）

| 前缀 | 含义 |
| --- | --- |
| ou | Unit 舰船 |
| ob | Object 场景物体 / 建筑 / 可破坏物 |
| oe | Effect 特效模型 |
| si_sbg / si_grd / si_sbf / si_sor | 天空球 / 地面 / 远景层 / 轨道层 |
| compass_ouXX | 该舰的 HUD 罗盘/选框（additive / opaque 两版） |
| ball/bounding | 包围球，碰撞用，非可见模型 |

| 标记 | 含义 |
| --- | --- |
| SB_ 前缀 | 最高精度完整模型（Super/Boss 级），**主力 LOD0** |
| 目录尾 a / b / c | 精度档：a=高、b=中、c=低（**c 档废弃不用**） |
| 部件内 U / M / L | Upper / Middle / Low 三级 LOD |
| E 后缀 | Enemy 敌方配色变体 |
| _body / _cannon / _aag / _missileA / _pod / _drill / _laser / _hou | 部件：本体 / 主炮 / 防空炮 / 导弹 / 吊舱 / 钻头 / 激光 / 尾翼 |
| _crash_3 / _S3 | 坠毁分段（5 段），暂不使用 |
| sim_ouXX | 简化舰模 |

## 三、实际面数与材质统计（scn1 全量，S0 实测）

| 档 | 文件数 | 顶点合计 | 面合计 |
| --- | --- | --- | --- |
| a 档（含 SB） | 161 | 295,598 | 257,683 |
| b 档 | 137 | 69,743 | 59,278 |
| c 档（废弃） | 101 | 18,836 | 14,480 |

**SB 模型池：31 个文件**
- 面数：最小 144 / 中位 5,138 / 最大 14,378 / 合计 176,838
- 材质数：1 个模型 2 个、2 个模型 6 个、3 个模型 3 个、4 个模型 4 个、5 个模型 1 个、6 个模型 9 个、8 个模型 2 个、10 个模型 3 个、11 个模型 1 个
- 结论：**单舰 2~11 个材质，中位 6 个**

## 四、性能结论（决定用什么档位）

面数**不是**瓶颈。580 (8G) + i5-9100F 的实际承受量：

| 场景 | 面数 | 判定 |
| --- | --- | --- |
| 同屏 50 艘 SB | 约 25 万面 | 无压力 |
| 同屏 150 艘 SB | 约 77 万面 | 完全可行 |
| 同屏 300 艘 SB | 约 150 万面 | 仍可行，瓶颈转移 |

真正的瓶颈是 **drawcall**：

- 单舰 6 个材质 → 6 个 drawcall → 加阴影 pass ×2 = 12
- 150 艘 = 1800 drawcall → 这里开始掉帧，且 9100F 是 4 核 4 线程，主线程提交是硬限制

所以优化优先级是：

1. **材质合并**（最高收益）：一艘船的 6 个材质 atlas 成 1~2 张，drawcall 直接降 3~6 倍
2. **部件合并**：同材质的多部件在 Blender 里合并成单个 mesh surface
3. **LOD**：不是为省面数，是为省顶点着色与带宽 —— SB(近) → U(中) → billboard(远) → 图标(极远)
4. **MultiMeshInstance3D**：小飞机集群（走同一条航线的那种）
5. **视锥剔除**：Godot 自动，不用写代码

## 五、档位使用策略（已定，见 ADR-0009）

**只导入 SB 一份资源，不产出 U/M/L 多套变体。**

| 项 | 做法 |
| --- | --- |
| 模型 | 只取 a 档里的 SB_（31 个文件） |
| 细节退化 | Godot 导入时自动生成 4 级 mesh LOD（generate_lods 默认 true） |
| 全局质量 | Viewport.mesh_lod_threshold（默认 1.0，远距离掉帧就往上调） |
| 逐模型微调 | GeometryInstance3D.lod_bias |
| 远处剔除 | visibility_range_begin / end / fade_mode |
| 极远 | billboard，再远用 UI 图标（表现层，不占模型资源） |
| **b / c 档** | **不使用，管线直接跳过** |

例外：a 档内并非每艘都有 SB（ou20a / ou21a / ou22a 只有 U）。这类船只有单档模型，直接当唯一档用。

### 合并策略的取舍

一个 glb 里若含多个 mesh 子节点，每个 mesh **独立**生成 LOD，各部件消失时机不一致（远景会看到船体没了但炮管还在）。所以：

- **按材质合并成 1~2 个 surface 再导出** → LOD 一致，顺带压 drawcall，这是主线做法
- **需要独立旋转的炮塔部件保持独立 mesh** → 接受各自 LOD 时机（炮塔体量小，影响可忽略）

## 六、转换流程（OBJ → GLB）

**为什么必须转**（Godot 能直接读 obj，但代价太高）：

1. 2362 个 obj = 2362 个独立导入项，.godot 缓存臃肿，编辑器打开变慢
2. 一艘船拆成 body / cannon / missileA / pod 多个 obj，运行时得自己拼装并计算炮塔 pivot
3. mtl 里的 _lum / _bmp / _ref 不会被自动接成 Emissive / Normal / Metallic
4. LOD 三档没有任何层级表达
5. OBJ 无骨骼无动画，将来挂引擎尾焰点、炮塔转向会很痛苦

**目标**：一艘船 = 1 个 glb，部件作为子节点保留层级，炮塔 pivot 归位到自身旋转中心。

### 步骤

1. **扫描**（已完成）：tools/model-pipeline/inventory-scn1.csv
2. **筛选**：只取 a 档目录 + **SB 模型**（+ ob 物体 + 选定特效），b/c 档跳过
3. **Blender headless 批处理**（Blender 4.5.0 已就位：C:\Program Files\Blender Foundation\Blender 4.5\blender.exe）：
   - 导入 OBJ（统一 up 轴与缩放，1 Blender unit = 1 m）
   - 部件合并 / 重命名（ounitid_partname）
   - 炮塔类部件的 pivot 移到自身包围盒中心
   - 朝向统一为 -Z 前方
   - MTL → Principled BSDF（_0 → Base Color，_0_lum → Emission，_0_bmp → Normal，_0_ref → Metallic/Roughness 参考）
   - 导出 .glb
4. **产物目录**（一个 ID 一个目录，一个 glb，无 LOD 变体）：
   ```
   assets/models/ships/ou134/ou134.glb
   assets/models/objects/ob1501/ob1501.glb
   assets/models/effects/...
   ```
5. **清单**：tools/model-pipeline/manifest.json（逻辑 ID → 文件 / LOD 组 / 尺寸 / 材质数 / pivot 表），入库

## 七、材质映射规范

| 原始贴图 | Godot 目标 |
| --- | --- |
| _0.png | Base Color（sRGB） |
| _0_lum.png | Emission（自发光，乘以 emission_strength） |
| _0_bmp.png | Normal Map（若为高度图需先转法线） |
| _0_ref.png | Metallic / Roughness 的参考，需估算统一值 |
| 缺失 | 统一 default 材质（metallic 0.2 / roughness 0.7） |
| .agi.png 后缀 | 批量重命名为 .png |

## 八、天空（背景球）

原素材：ek/axo/stage/<关>/si_sbg_*/，单个球体顶点达 ±33000~50000，由 8~10 层贴图叠加（星空底 si_abg / 大气 / 太阳 si_sun / 云 si_sbo / 星云 si_sbs / 轨道 si_sor）。

**不要把它当 mesh 放进场景**。5 万单位的球 + 100 单位的船，相机 far 要开到 10 万，深度精度崩溃，舰体会闪（z-fighting）。

正确做法：

1. **主方案**：把各层烘成 equirectangular 全景图（HDR）→ Godot Sky + PanoramaSkyMaterial。Sky 不参与深度、不占几何，还顺带给全场景环境光。
2. **可选**：保留 1~2 层动态视差（太阳 / 星云），用 mesh 球实现 —— 法线翻转朝内（材质 Cull Mode = Front，即玩家说的"反过来"），unshaded、关深度测试、跟随相机、半径递减。

## 九、待办

- [ ] 安装 Blender（本机未装，需手动下载）
- [ ] 写 batch_obj2glb.py（Blender headless 脚本）
- [ ] 生成 manifest.json
- [ ] 材质 atlas 合并策略（决定能否做到 1~2 材质/舰）
- [ ] 炮塔 pivot 自动推算规则
- [ ] 天空球烘焙脚本
