# GA-RTS 架构

> 本文档记录**架构事实**，改动极少。所有"为什么这么选"在 docs/adr/ 里。
> 最后更新：S0

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
L0 数据层   scripts/data/  data/*.tres
              ▲
              │  只读
L2 表现层   scenes/  模型 / 特效 / 相机 / HUD
```

依赖只允许向下与向左。**禁止**：L1 依赖 L2；L2 回写 L1；L0 引用任何运行时对象。

## 六条硬规则

1. **单一命令入口**：唯一能改变单位指令状态的函数是 CommandBus.issue()。仲裁规则（玩家命令覆盖自动命令；玩家命令在位期间拒绝自动命令）在 CommandBus 内部实现，不在调用方。
2. **单一更新驱动**：单位不得在自己的 _process / _physics_process 里推进自己。全部由 Simulation 在一处按固定步长 tick。每个单位每 tick 只允许一次位移积分（用断言保护）。
3. **表现层只读**：Node3D 只读模拟数据做插值渲染。任何"看起来该动一下"的视觉效果都不得写回模拟字段。
4. **资源路径不硬编码**：代码里不得出现 res://assets/... 字面量，一律通过 AssetCatalog 按逻辑 ID 取。这样以后换 pck / 画质包 / mod 不用改业务代码（见 ADR-0006）。
5. **同一逻辑只有一份**：2D 模式是**镜头**，不是第二套模拟。任何"2D 模式下也要不一样处理"的想法，先确认能否用 ViewProjection 解决。
6. **尺度写死**：所有尺寸/距离/速度都基于 1 unit = 1 m，见 docs/scale-and-units.md。

## 目录职责

| 目录 | 职责 | 不做什么 |
| --- | --- | --- |
| scripts/core/ | GameState（全局容器）、Simulation（tick 驱动）、CommandBus、SceneDirector（场景状态机）、Config | 不含单位逻辑 |
| scripts/battle/unit/ | Unit 数据对象 + 移动 / 飞行 / 状态 / 战斗 / 索敌 / 后勤 分模块 | 不碰渲染 |
| scripts/battle/ai/ | 策略 / 焦点 / 执行 / 战斗控制 四层舰队 AI | 不发玩家命令 |
| scripts/battle/skills/ | 必杀注册表与实现 | 不直接改单位，走 CommandBus |
| scripts/systems/navigation/ | 可视图 + Dijkstra 寻路服务（见 ADR-0004） | 不持有单位状态 |
| scripts/systems/maps/ | 地图加载、初始单位投放 | 不做地形渲染 |
| scripts/systems/terrain/ | 障碍物的数据形态与查询 | 不做导航算法 |
| scripts/data/ | Resource 类定义（UnitDef / WeaponDef / SkillDef / MapDef / TeamDef） | 不含逻辑 |
| scripts/assets/ | AssetCatalog（逻辑 ID → 资源） | 不做加载编排 |
| scripts/camera/ | 相机策略（2D 正交 / 3D 焦点轨道） | 不做拾取 |
| scripts/input/ | InputRouter → ViewProjection → CommandBus 链路 | 不直接改单位 |
| scripts/ui/ | HUD / 面板 / 选择框 / 右键菜单 | 不缓存模拟真值，只读快照 |
| scenes/ | 与 scripts/ 镜像的节点树 | 不放逻辑 |
| data/ | .tres 实际数据 | 不放脚本 |
| assets/ | 模型 / 材质 / 贴图 / 音频 / 天空 | 不放 .gd |
| tools/ | 离线脚本（模型管线等），不参与运行时 | — |
| tests/ | gdUnit4 套件 | — |

## 四个核心接口

| 接口 | 职责 | 存在理由 |
| --- | --- | --- |
| **ViewProjection** | world_to_screen / screen_to_world / pick_point / pick_rect | 双视图唯一的差异点。上层全部通过它，因此不知道当前是 2D 还是 3D |
| **CommandBus** | issue(unit_or_group, kind, options) + 信号 | 单一写入者，仲裁集中，可单测 |
| **AssetCatalog** | 逻辑 ID → 路径 / LOD 组 / 材质组 | 资源可迁移、可分包、可换肤 |
| **NavService** | route(from, to, radius, height) → PackedVector3Array | 寻路可替换、可测试、可分批摊销（9100F 是 4 核，寻路不能一帧算满） |

## 模拟循环顺序（每 tick，固定顺序不得打乱）

1. 输入命令队列 flush（CommandBus 排空）
2. 全局时钟 / 经济 / 任务目标
3. 每单位：状态机决策 → 索敌 → 移动积分（唯一一次） → 武器冷却 → 开火
4. 弹体推进与命中判定
5. 技能任务 tick
6. 死亡清理 / 胜负判定
7. 快照发布（表现层读取）

## 仿真精度分层（性能手段，S3 实现）

| 层级 | 条件 | 精度 |
| --- | --- | --- |
| full | 在相机视锥内 或 正在交战 | 全逻辑 + 全特效 + 全 AI |
| reduced | 视锥外但已激活 | 全逻辑，跳过特效与寻路重算（沿旧航线） |
| dormant | 远离战场 / 未被发现 | 每 N tick 更新一次位置与状态 |

这条是架构预留，S0 只保证分层点存在，不实现。

## 待定事项

- 战争迷雾：原 2D 版无迷雾，3D 版是否引入 —— 待定，未开工
- 单位间分离力：原版无碰撞，3D 版必须补 —— 计划在 S3
- 编队阵型：原版"跟随 = 追尾"，3D 需要真阵型 —— 计划在 S3
- 损伤分段模型（_crash_S0~S4）：是否启用待定
- 多线程：Simulation 目前设计为单线程固定步长，寻路已预留批次摊销接口
