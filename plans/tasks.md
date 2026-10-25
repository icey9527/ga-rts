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

T-2.5 两军各 5 单位对战验证（S2 收尾卡）

---

## S1 竖切片 ✅

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

## S2 模拟闭环（当前主线）

目标：两军打起来，能分出胜负。

### T-2.0 数据补全 ✅

- **交给**：worker（25 分钟硬超时中断，代码已完成但未自检，主代理补验收）
- **产出**：`unit.tbl` 补全运动参数 + 删 DEFAULTS 兜底；`skirmish` 地图表化（含 top=200 低层 / top=800 高层障碍）
- **约束**：缺键即炸，不准静默兜底 —— 数据错误必须当场暴露而不是变成 0

### T-2.1 状态机与集中选靶 ✅

- **产出**：`unit_states.gd`、`targeting.gd`（303 行）、`squad.gd`、`battle_context.gd`
- **要点**：接近时间排序 / 咬尾优先 / 1 秒节流；编队级集中选靶，AI 只读 BattleContext 不摸 Session

### T-2.2 武器与炮塔 ✅

- **产出**：`weapon_def.gd`、`weapon_mount.gd`（转向限速 + 冷却）、`unit_weapons.gd`
- **数值**：`heavy_beam`（2000 m / 45°/s / 3.2 s，ou134 ×4）、`pulse_cannon`（700 m，ou05 ×2）

### T-2.3 弹体与扫掠命中 ✅

- **交给**：主代理亲自写（复杂几何判定，不交子代理）
- **产出**：`projectile.gd`、`projectile_manager.gd`、`verify_projectile.gd`（25 断言）
- **核心**：弹速 2000 m/s + 60 Hz → 每 tick 33.33 m，目标厚 10 m，**点判定必穿透**
- **解耦**：Manager 只产命中记录，伤害由目标侧 `apply_damage()` 唯一入口结算

### T-2.4 死亡清理与请求-结算 ✅

- **交给**：主代理亲自写
- **产出**：`session.gd` 请求表（`request_spawn` / `request_kill`）+ `_resolve_requests` 两段式、`verify_death.gd`（43 断言）
- **核心**（ADR-0012 机制 #4）：遍历中不改集合 —— 第 1~7 步集合恒定，第 8 步统一结算
- **信号时机**：`unit_died` 发在集合变更**之后**，监听者看到的 session 始终自洽

### T-2.5 两军对战验证（待做）

- **验收**：两军各 5 单位打起来，能分出胜负

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
| T-2.0 数据补全（unit.tbl 运动参数 + skirmish 地图表化） | v1.0.0-s2 |
| T-2.1 状态机 + 编队集中选靶（接近时间排序 / 咬尾 / 1 秒节流） | v1.1.0-s2 |
| T-2.2 武器数据 + 炮塔转向冷却，28 条断言全过 | v1.2.0-s2 |
| T-2.3 弹体与扫掠命中（命中-伤害解耦），25 条断言全过 | v1.3.0-s2 |
| T-2.4 死亡清理与请求-结算两段式，43 条断言全过 | v1.4.0-s2 |

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
| 编辑函数体时张冠李戴 | `clear_damaged` / `mark_damaged` 的函数体写串 → 重复声明 → **42 个脚本一起 Parse Error**；改完必须全量 gdcheck，不能只看目标文件 |
| 扫掠判定的半径 | 组合半径 = 目标半径 + 弹体半径；断言“命中点在球面”时漏算弹体半径会误判为失败（**测试错了不是实现错了**） |
| Dictionary 取值推断类型 | `dict["k"].method()` 无法推断类型，需显式声明 `var x: float = (... as Vector3).method()` |
