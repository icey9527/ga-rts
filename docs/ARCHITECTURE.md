# GA-RTS 架构

> 本文档记录**架构事实**，改动极少。所有"为什么这么选"在 docs/adr/ 里。
> 最后更新：S1 前（纳入 ADR-0012~0014：Sylpheed 引擎框架、碰撞与扫掠弹体、关卡编排）

## 一句话

**一套 3D 模拟，两套视图。** 模拟层不依赖节点；表现层只读不写；所有命令只有一个入口。

## 四层与依赖方向

```
L3 交互层   scripts/input/  scripts/ui/
              │  只发命令，不写状态
              ▼
L1 模拟层   scripts/core/  scripts/battle/  scripts/systems/
              │  纯数据 + Vector3 数学，不依赖任何场景节点
              ▼
L0 数据层   content/*.tbl  +  scripts/core/tbl.gd  scripts/core/registry.gd
              ▲
              │  只读
L2 表现层   scenes/  模型 / 特效 / 相机 / HUD
```

依赖只允许向下与向左。**禁止**：L1 依赖 L2；L2 回写 L1；L0 引用任何运行时对象。

数据层用 TBL 文本而非 .tres（见 ADR-0008）：代码库只有一个硬编码路径 `res://content/base.tbl`，
其余全部按逻辑名走注册表。

## 八条硬规则

1. **单一命令入口**：唯一能改变单位指令状态的函数是 CommandBus.issue()。仲裁规则（玩家命令覆盖自动命令；玩家命令在位期间拒绝自动命令）在 CommandBus 内部实现，不在调用方。
2. **单一更新驱动**：单位不得在自己的 _process / _physics_process 里推进自己。全部由 Simulation 在一处按固定步长 tick。
3. **累加器**：单位每 tick 只写期望增量（accum_position / accum_rotation / accum_speed），Simulation 在 tick 末尾统一应用并清零。状态切换不留残余速度（ADR-0012）。
4. **表现层只读**：Node3D 只读模拟数据做插值渲染。任何"看起来该动一下"的视觉效果都不得写回模拟字段。
5. **资产名不硬编码**：代码里不得出现任何资源路径字面量。一律用逻辑名，经注册表解析；实际路径只存在于 `content/assets/assets.tbl`（ADR-0008）。
6. **遍历中不改集合**：增删走请求表，帧内固定点统一结算（ADR-0012）。Godot 侧用延迟队列，不用裸 remove。
7. **同一逻辑只有一份**：2D 模式是**镜头**，不是第二套模拟。任何"2D 模式下也要不一样处理"的想法，先确认能否用 ViewProjection 解决。
8. **尺度写死**：所有尺寸 / 距离 / 速度都基于 1 unit = 1 m，见 docs/scale-and-units.md。

## 目录职责

| 目录 | 职责 | 不做什么 |
| --- | --- | --- |
| scripts/core/ | GameState、Simulation、CommandBus、SceneDirector、tbl.gd（解析）、registry.gd（注册表） | 不含单位逻辑 |
| scripts/battle/unit/ | Unit 数据对象 + 移动 / 飞行 / 状态 / 战斗 / 索敌 / 后勤 分模块 | 不碰渲染 |
| scripts/battle/ai/ | 编队行为栈 + 个体状态机 + 集中选靶（ADR-0012） | 不发玩家命令 |
| scripts/battle/skills/ | 必杀注册表与实现 | 不直接改单位，走 CommandBus |
| scripts/systems/navigation/ | 可视图 + Dijkstra 寻路服务（ADR-0004） | 不持有单位状态 |
| scripts/systems/mission/ | 关卡编排、帧对比触发器、对话三管道（ADR-0014） | 不做单位逻辑 |
| scripts/systems/terrain/ | 障碍物的数据形态与查询 | 不做导航算法 |
| scripts/data/ | TBL 结构体定义（UnitDef / WeaponDef 等，普通 RefCounted，非 Resource） | 不含逻辑 |
| scripts/assets/ | 资产解析：逻辑名 → 路径（薄层，数据在 assets.tbl） | 不做加载编排 |
| scripts/camera/ | 相机策略（2D 正交 / 3D 焦点轨道） | 不做拾取 |
| scripts/input/ | InputRouter → ViewProjection → CommandBus 链路 | 不直接改单位 |
| scripts/ui/ | HUD / 面板 / 选择框 / 右键菜单 | 不缓存模拟真值，只读快照 |
| scenes/ | 与 scripts/ 镜像的节点树 | 不放逻辑 |
| content/ | base.tbl、各类 TBL、资产引用表 | 不放脚本 |
| assets/ | 模型 / 材质 / 贴图 / 音频 / 天空 | 不放 .gd |
| tools/ | 离线脚本，不参与运行时（`.gdignore` 屏蔽） | 游戏代码不得引用 |
| tests/ | gdUnit4 套件 | — |

## 五个核心接口

| 接口 | 职责 | 存在理由 |
| --- | --- | --- |
| **ViewProjection** | world_to_screen / screen_to_world / pick_point / pick_rect | 双视图唯一的差异点。上层全部通过它，因此不知道当前是 2D 还是 3D |
| **CommandBus** | issue(unit_or_group, kind, options) + 信号 | 单一写入者，仲裁集中，可单测 |
| **Registry** | 逻辑名 → 数据 / 资产，含四级覆盖链 | 加单位 / 加队伍 / 换皮肤不改代码，mod 可用记事本改 |
| **NavService** | route(from, to, radius, height) → PackedVector3Array | 可替换、可测试、可时间预算摊销 |
| **Simulation** | 固定步长 tick，唯一驱动点 | 模拟层可脱离场景单测 |

## 模拟循环顺序（每 tick，固定顺序不得打乱）

1. 命令队列 flush（CommandBus 排空，仲裁已在此完成）
2. 全局时钟 / 经济 / 任务目标 / 触发器帧对比判定
3. 每单位：行为栈 / 状态机决策 → 索敌 → 移动累积 → 武器冷却 → 开火请求
4. **累加器统一应用**（位置 / 朝向 / 速度一次性写回，然后清零）
5. 弹体推进 + **扫掠命中检测**（ADR-0013）
6. 命中信号派发 → 目标侧结算伤害（解耦）
7. 技能任务 tick
8. 请求表结算（死亡清理、生成）
9. 胜负判定 → 快照发布（表现层读取）

## 碰撞与弹体（ADR-0013）

三层碰撞体，互不复用：

| 层 | 用途 | 实现 |
| --- | --- | --- |
| hittable | 被弹体命中，部件级 | ConcavePolygonShape3D（大舰）/ 凸包（小艇），只被扫掠查询 |
| blocker | 单位间阻挡与规避 | 单凸包或球 |
| sensor | AI 感知与分离力 | **不走物理**，自建空间哈希 + 球 |

**弹体一律扫掠**：碰撞体是「上一帧位置 → 当前位置」的线段，用 ShapeCast3D。
不做点碰撞。不做子步进。高速武器穿透在 3D 尺度下是必然事件，不扫掠等于埋雷。

命中只发信号，伤害由目标侧结算 —— 弹体不修改目标状态。

## AI 结构（ADR-0012）

```
编队层   可抢占行为栈（Array 当栈，行为 = RefCounted + update(dt) -> bool）
           └ 集中选靶：编队共享目标，Timer 节流，按「预计接近时间」排序，被咬尾时后方优先
个体层   状态机（约 10 个状态）
           └ 只写累积增量，不直接改 transform
```

行为栈的价值：「去 A 点途中被打 → 插入反击 → 反击结束自动继续去 A 点」是免费的。
代价是调试时看不出"它现在在干嘛"，因此**必须配套行为栈可视化**。

## 仿真精度分层（性能手段，S3 实现）

| 层级 | 条件 | 精度 |
| --- | --- | --- |
| full | 在相机视锥内 或 正在交战 | 全逻辑 + 全特效 + 全 AI |
| reduced | 视锥外但已激活 | 全逻辑，跳过特效与寻路重算（沿旧航线） |
| dormant | 远离战场 / 未被发现 | 每 N tick 更新一次位置与状态 |

降级单位 = 编队整体升降（照抄 Sylpheed 的 SetProcessingLevel 粒度），不是逐单位判断。
摊销用**时间预算制**，不用固定分桶。

## 渲染与资产

- 只导入一份 SB 模型，LOD 全部交给引擎自动生成（ADR-0009）
- 资源包为 `.dat`（ADR-0010），可多包挂载，挂载顺序即覆盖优先级
- 天空用 Sky 资源，不放置 mesh 天球（5 万单位会毁掉深度精度）

## 待定事项

- 战争迷雾：原 2D 版无迷雾，3D 版是否引入 —— 待定
- 单位间分离力：用物理推动还是纯逻辑分离力 —— 倾向后者，S3
- 编队阵型：原版"跟随 = 追尾"，3D 需要真阵型 —— S3
- 损伤分段模型（_crash_S0~S4）：是否启用待定
- 部件级血量（打掉炮塔后该武器失效）：S2 先做整体血量，S3 再评估
- 多线程：Simulation 单线程固定步长；寻路与 AI 预留时间预算摊销接口
