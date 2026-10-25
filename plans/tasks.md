# 任务卡（执行单元）

> 工作方式：主代理拆任务卡 → 指定子代理执行 → 主代理独立验收 → 提交。
> 验收一律**不采信子代理自述**，主代理自己跑命令。

## 代理分工（2026-10-25 定）

| 代理 | 模型 | 思考 | 干什么 |
| --- | --- | --- | --- |
| scout | `GLM-5.3-Flash` | high | **看图**、扫目录、简单查找 |
| tester | `GLM-5.3-Flash` | high | 跑检查、跑测试、如实报错 |
| worker | `glm-5.3` | high | **复杂编码** |
| general-purpose | `glm-5.3` | high | 无专用代理可用的杂活 |
| planner | `glm-5.3` | high | 方案与取舍（只读） |
| reviewer | `glm-5.3` | high | 代码评审（只读） |

**禁用 `glm-5.1`**。改完定义后需执行 `/subagent reload`。

---

## 进行中

### T-0.5.1 特效管线（S0.5 收尾）

- **交给**：worker
- **输入**：`F:/godot/model/el/scn0/oe*`（76 个）、`F:/godot/model/ek/axo/effects/si_e*`（约 130 个）
- **产出**：
  - `tools/pipeline/model-pipeline/batch_effects.py`
  - `assets/models/effects/<id>/<id>.glb`
  - `content/assets/assets.tbl` 补 `[vfx]` 节
- **约束**：特效模型多为贴图公告板，不要当实体网格处理；带 alpha 的按透明材质导出
- **验收**：
  1. 主代理跑转换，统计产出数量与体积
  2. 抽样 2 个在 `scenes/dev/verify_assets.tscn` 里渲染，**由 scout 看图**确认效果
  3. `verify_registry.tscn` 资产数增加且错误数为 0

---

## S1 竖切片（下一步主线）

目标：一艘船能绕障碍飞到指定点，双相机可切换。

### T-1.1 项目配置与骨架

- **交给**：worker
- **产出**：
  - `project.godot`：autoload（Registry / GameState / CommandBus / Simulation）、`[input]` 映射
  - `scenes/main.tscn` + `scripts/core/main.gd`
  - `scenes/battle/battle.tscn`
- **约束**：input 键位名必须与 `docs/controls.md` 一致（snake_case）
- **验收**：Godot 启动无报错，autoload 全部就位，InputMap 键位齐全

### T-1.2 相机（双视图）

- **交给**：worker
- **产出**：`scripts/camera/view_projection.gd`、`rts_camera_3d.gd`、`rts_camera_2d.gd`、`scenes/camera/rts_camera.tscn`
- **约束**：见 ADR-0002；3D 焦点轨道（禁自由飞行）、2D 正交保留原版拖拽；缩放改距离不改 FOV
- **验收**：3D 能绕焦点转/平移/缩放；2D 能拖拽/缩放；Tab 切换有 0.4s 过渡；相机不穿地

### T-1.3 视图投影与拾取

- **交给**：worker
- **产出**：`scripts/camera/view_projection.gd` 的四个方法 + `scripts/input/input_router.gd`
- **约束**：**双视图唯一差异点**，业务代码不得出现 `if is_2d`
- **验收**：同一份框选逻辑在 2D/3D 下都能选中单位；单元测试覆盖 `screen_to_world` 往返

### T-1.4 寻路服务

- **交给**：worker
- **产出**：`scripts/systems/navigation/nav_obstacle.gd`、`nav_graph.gd`、`navigation_service.gd`
- **约束**：见 ADR-0004；XZ 平面可视图 + Dijkstra，障碍当柱体按 y 过滤；必须支持分帧摊销
- **验收**：
  - 单测：直线可见返回单点；被挡返回绕行点；目标在膨胀圈内自动推到圈外
  - 实跑：一艘船绕一颗小行星飞到目标点

### T-1.5 单位与移动

- **交给**：worker
- **产出**：`scripts/battle/unit/unit.gd`、`unit_movement.gd`、`unit_flight.gd`、`scenes/units/unit_base.tscn`
- **约束**：见 ADR-0003；累加器模式（只写 accum_*）；速度沿机头；机头不对就减速
- **验收**：
  - 单测：加速/减速曲线、转向角速度上限、每 tick 只积分一次（断言）
  - 实跑：转弯时不会瞬间横移

### T-1.6 竖切片联调

- **交给**：general-purpose
- **输入**：T-1.1 ~ T-1.5
- **验收**：点选一艘船 → 右键点目标点 → 船沿导航绕过障碍抵达；2D/3D 切换后位置一致

---

## 待定（不阻塞 S1）

- 战争迷雾是否引入
- 损伤分段模型是否启用
- 小飞机是否走 MultiMesh 集群
- TBL `base` 继承机制（P2）

---

## 已完成

| 任务 | 完成 |
| --- | --- |
| 模型管线 29 个 glb | v0.1.1-s0.5 |
| 天空烘焙 15 套 equirect | v0.2.0-s0.5 |
| Godot 内资产验证 | v0.3.0-s0.5 |
| 数据注册表（TBL 解析 + 校验） | v0.4.0-s0.5 |
