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

（无 —— S0.5 已完成，待开 S1）

---

## S1 竖切片（下一步主线）

目标：一艘船能绕障碍飞到指定点，双相机可切换。

### T-1.1 项目配置与骨架 ✅

- **交给**：worker
- **产出**：
  - `project.godot`：autoload（Registry / GameState / CommandBus / Simulation）、`[input]` 映射
  - `scenes/main.tscn` + `scripts/core/main.gd`
  - `scenes/battle/battle.tscn`
- **约束**：input 键位名必须与 `docs/controls.md` 一致（snake_case）
- **验收**：Godot 启动无报错，autoload 全部就位，InputMap 键位齐全

### T-1.2 相机（双视图）✅

- **交给**：worker
- **产出**：`scripts/camera/view_projection.gd`、`rts_camera_3d.gd`、`rts_camera_2d.gd`、`scenes/camera/rts_camera.tscn`
- **约束**：见 ADR-0002；3D 焦点轨道（禁自由飞行）、2D 正交保留原版拖拽；缩放改距离不改 FOV
- **验收**：3D 能绕焦点转/平移/缩放；2D 能拖拽/缩放；Tab 切换有 0.4s 过渡；相机不穿地

### T-1.3 视图投影与拾取 ✅

- **交给**：worker
- **产出**：`scripts/camera/view_projection.gd` 的四个方法 + `scripts/input/input_router.gd`
- **约束**：**双视图唯一差异点**，业务代码不得出现 `if is_2d`
- **验收**：同一份框选逻辑在 2D/3D 下都能选中单位；单元测试覆盖 `screen_to_world` 往返

### T-1.4 寻路服务 ✅

- **交给**：worker
- **产出**：`scripts/systems/navigation/nav_obstacle.gd`、`nav_graph.gd`、`navigation_service.gd`
- **约束**：见 ADR-0004；XZ 平面可视图 + Dijkstra，障碍当柱体按 y 过滤；必须支持分帧摊销
- **验收**：
  - 单测：直线可见返回单点；被挡返回绕行点；目标在膨胀圈内自动推到圈外
  - 实跑：一艘船绕一颗小行星飞到目标点

### T-1.5 单位与移动 ✅

- **交给**：worker
- **产出**：`scripts/battle/unit/unit.gd`、`unit_movement.gd`、`unit_flight.gd`、`scenes/units/unit_base.tscn`
- **约束**：见 ADR-0003；累加器模式（只写 accum_*）；速度沿机头；机头不对就减速
- **验收**：
  - 单测：加速/减速曲线、转向角速度上限、每 tick 只积分一次（断言）
  - 实跑：转弯时不会瞬间横移

### T-1.6 竖切片联调 ✅

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
| 特效管线 208 个公告板 glb | v0.5.0-s0.5 |
| T-1.1 项目配置与骨架（3 autoload + 23 个 InputMap action + main/battle 场景） | v0.6.0-s1 |
| T-1.2 双相机（3D 焦点轨道 / 2D 正交 / CameraRig / ViewProjection），43 条断言全过 | v0.6.0-s1 |
| T-1.3 输入路由 InputRouter（720 行）+ 接线，68 条断言全过 | v0.7.0-s1 |
| T-1.4 寻路服务（可视图 + Dijkstra），39 条断言全过 | v0.7.0-s1 |
| T-1.5 单位与移动（累加器 + 飞机式积分 + 分层高度 + 表现层），56 条断言全过 | v0.8.0-s1 |
| T-1.6 竖切片联调（选船 → 右键 → 绕障碍抵达），48 条断言全过，S1 完成 | v0.9.0-s1 |

## 管线坑（攒下来，别再踩）

| 坑 | 说明 |
| --- | --- |
| 材质漏接 Material Output | 节点树没输出，渲染全黑且不报错 |
| `mesh.materials.clear()` | 会重置所有面的 material_index，必须先缓存后写回 |
| Blender 相对路径渲染 | 写到进程工作目录（实测 `C:\tools`），必须 resolve 成绝对路径 |
| 天空/特效贴图无 alpha | 黑色区域才是透明，透明度需从亮度推导 |
| Blender 导出器表达力不足 | “贴图提供 alpha 但 RGB 乘 0” 无法直接导出，需补 GLB JSON chunk |
| Godot 导入不全 | 首次可能只导一部分且不自动补扫，需删 filesystem cache 重扫；易误判为管线漏产 |
| 断言结构化数据 | 用正则匹配 JSON 原文会因空格失效，应解析后断言 |
