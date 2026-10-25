# ADR-0004 寻路：XZ 平面可视图 + Dijkstra，不用 NavMesh

- 状态：已采纳
- 日期：S0

## 背景

原版 systems/navigation.lua 的做法：
- 不是 A* 栅格，是**可视图（visibility graph）+ Dijkstra**
- 障碍按 unit.z 与障碍高度过滤（z 高于障碍则可直飞）
- 膨胀半径 = 障碍 r + 单位 r + 4
- 目标点落在膨胀圈内则沿径向推到圈外
- 直线可见就直接返回单点路径
- 否则每个障碍圈撒 12 个方位节点，跑 Dijkstra

原版没有网格、没有战争迷雾。

## 选项

1. Godot NavigationRegion3D + NavMesh + NavigationAgent3D
2. 3D 体素 A*（真三维栅格）
3. **保留可视图，把障碍当柱体，在 XZ 平面计算**

## 结论

选 3。

理由：

- NavMesh 烘出来的是"从上方可达的表面"，适合**地面单位**，不适合体积飞行的飞船
- 3D 体素 A* 对 30 km 战场是灾难（内存与预计算），对 RTS 收益极低
- 可视图天然支持"空中绕柱子"，与本作的分层高度完全同构：只要 unit.y > 柱顶，该障碍直接从障碍表中剔除 —— **等价于原版的 z 过滤，代码几乎照抄**
- 单位规模（几十到 200）下，可视图 + Dijkstra 比 3D 栅格更轻

## 实现要点

- 障碍抽象为 NavObstacle：position / radius_xz / top_y / bottom_y / inflate_factor
- 膨胀半径取 XZ 投影半径（飞船宽度）
- 目标点若在膨胀圈内，沿径向推到圈外（沿用原版做法）
- 返回 PackedVector3Array，Y 取该障碍顶或该层巡航高度
- NavigationService 必须支持**分批摊销**（每帧只算 N 个单位的路径），因为 i5-9100F 是 4 核 4 线程
- 保留运行时调试绘制（F3），否则 3D 里没法排查

## 代价

- 障碍必须近似为圆柱/胶囊，不能是任意凸体
- 障碍极密时（碎带）节点数会爆，需要设障碍数量上限或分区

## 影响

scripts/systems/navigation/、scripts/systems/terrain/、docs/ARCHITECTURE.md 的 NavService 接口
