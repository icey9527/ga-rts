# 数据注册表与资产引用

> 目标：代码里**不出现任何资产名和路径**；加新机型 / 新队伍 / 新角色 = 丢一个文件夹；换资产 = 改一个 TBL。
> 参考了原 Love2D 版的 TBL 系统（core/tbl.lua + content/units/<id>/unit.tbl）与《银河天使》的 ga_base.tbl 单入口思路。

## 一、总原则

1. **全项目只有一个写死的路径**：res://content/base.tbl
2. **目录名即 ID**：content/units/fighter/ 里的 fighter 就是单位 ID，不在数据文件里重复声明
3. **资产名与逻辑名分离**：代码只认逻辑 ID（如 ou134），逻辑 ID 到文件的映射在 TBL 里
4. **覆盖链**：附加包 > 本体 > 皮肤变体 > 占位
5. **加载期统一乘倍率**：TBL 里写的永远是"设计口径"数值，pacing 倍率在主循环时乘入，不污染数据
6. **坏数据必须炸**：启动时全量校验，缺失资产 / 重复 ID / 非法键直接报错并列出，不允许静默降级

## 二、唯一硬编码入口

`res://content/base.tbl` —— 整个代码库里唯一出现的字面路径。

```ini
[registry]
units   = units/units.tbl
teams   = teams/teams.tbl
maps    = maps/maps.tbl
assets  = assets/assets.tbl
audio   = audio/audio.tbl
sky     = sky/sky.tbl
pacing  = config/pacing.tbl

[roots]
content = res://content
assets  = res://assets

[mounts]
; 运行时按顺序 load_resource_pack，后加载的覆盖先加载的
; 文件放游戏目录，扩展名用 .dat
; packs = 02_content.dat, 03_hd_models.dat

[debug]
hot_reload = false      ; 开发期打开，F5 重载 content/ 不重启
validate_on_start = true
```

## 三、类别表（taxonomy）—— 加新"类"不用改代码

`content/units/units.tbl` 不是单位清单，是**单位这个类别的扫描规则**：

```ini
[type.unit]
dir      = content/units
manifest = unit.tbl          ; 必需文件，缺了就不注册
optional = behavior.lua, skill.lua, weapons.tbl, se.tbl
id_from  = dirname           ; 目录名即 ID

[type.team]
dir      = content/teams
manifest = team.tbl
id_from  = dirname
```

注册表里**不列 ID**。加新单位就是往 content/units/ 丢一个目录，运行时扫描自动发现——
这正是原 Love2D 版验证过的模式（plans/README.md 里明确记录过"chara.tbl 里声明 ID 是脱裤子放屁"，注册表被删掉了）。

如果哪天确实需要"只启用部分内容"，在 base.tbl 里加一个白名单节，而不是回到逐条列举。

## 四、资产引用表

`content/assets/assets.tbl` —— 逻辑名 → 相对 res://assets/ 的路径，**不带扩展名**（引擎按导入产物自动找）。

```ini
[ship]
ou134   = models/ships/ou134/ou134
ou01    = models/ships/ou01/ou01
ou241   = models/ships/ou241/ou241

[prop]
ob1501  = models/objects/ob1501/ob1501
asteroid_s = models/objects/ob1401/ob1401

[texture.ui]
frame.default = textures/ui/frame_default
cursor.move   = textures/ui/cursor_move

[audio.se]
fire.light    = audio/se/se_light_01
explode.small = audio/se/exp_small_01

[vfx]
beam.pulse    = effects/beam_pulse

[sky]
skirmish  = sky/panorama_skirmish
tutorial  = sky/panorama_tutorial
```

代码侧只写：`Assets.ship("ou134")` / `Assets.se("fire.light")`。
**换模型文件、改名、替换成 mod 资源 → 只改这张表。**

## 五、覆盖链（4 级，从高到低）

| 优先级 | 来源 | 用途 |
| --- | --- | --- |
| 1 | 附加包（.dat 挂载根） | mod、画质包、DLC |
| 2 | res://content/ 本体 | 正式内容 |
| 3 | 皮肤/变体目录 | content/units/<id>/skins/<skin>/ 镜像覆盖本体同名文件 |
| 4 | 占位资源 | 缺失时用，且**记录一条警告** |

皮肤覆盖沿用原版做法：skins/<name>/ 下目录结构与本体镜像，同名文件覆盖，缺的回落到本体。

## 六、TBL 格式（GDScript 版，在 Lua 版基础上补三件事）

原版语法：`[section]` + `key = value` + 数组 `{a,b,c}` + 注释 `;`/`#` + 引号字符串 + 自动数字/布尔转换。

**补品一：点号分层**
`[weapon.main]` 展开为 section "weapon" 下的子键 "main"，而不是一个名叫 "weapon.main" 的扁平键。
（原版这里是坑：`[weapon.*]` 前缀匹配展开成武器表，靠调用方手工处理。）

**补品二：类型标注（可选）**
`energy_cost:int = 5` / `accent:color = "#FFB84D"` / `size:vec3 = 1,2,3`
不写就自动推断，写了就强校验。数据驱动最大的坑是拼错没报错，类型标注是解药。

**补品三：继承（可选，P2）**
`base = content/units/fighter/unit.tbl` 让 mod 机型能从模板派生出变体，只覆盖差异字段。
原版没有这个机制，导致 15 个机型包里大量重复数值。

## 七、加载流程

```
启动
 └─ Registry.load()
     ├─ 读 res://content/base.tbl           ← 唯一硬编码
     ├─ 按 [mounts] 依次 load_resource_pack(.dat)
     ├─ 按 [roots] 建立根目录优先级
     ├─ 遍历 [registry] 每个类别
     │   ├─ 扫 dir/*/manifest
     │   ├─ 解析 TBL → 类型化字典
     │   ├─ 应用覆盖链（外 → 内）
     │   └─ 校验（重复 ID / 缺文件 / 类型错 / 资产缺失）
     ├─ 生成 report：registry_report.txt
     └─ 提供只读访问 API（Registry.units / Registry.asset(id) …）
```

## 八、校验清单（启动时全跑，缺一项都算失败）

- [ ] manifest 存在的目录才能注册，否则跳过并警告
- [ ] ID 重复（同名目录出现在两个挂载根）→ 报错，按覆盖链取胜者并记录
- [ ] 资产引用指向的文件是否存在（按逻辑名查 assets.tbl，再查实际文件）
- [ ] 必需键是否齐全（[stats] 里的 name / speed / max_hp 等）
- [ ] 类型标注是否匹配
- [ ] 数组长度是否一致（如 spawn 的 {x,y,z} 三维）
- [ ] 单位引用的机型 ID 是否存在（队伍 → 角色 → 机型的三级引用）
- [ ] 技能 type 是否有对应实现
- [ ] 声音槽名是否在允许的枚举内

## 九、与原 Lua 版的对照

| 原版 | Godot 版 | 变化 |
| --- | --- | --- |
| 扫描 content/units 找 unit.tbl | 同，DirAccess 扫 | 保留 |
| TBL 两层扁平 | 点号分层 + 类型标注 | 改进 |
| 无 include | 可选 base 继承 | 新增 |
| 资产写相对路径散落各处 | 集中到 assets.tbl | 改进 |
| 皮肤目录镜像覆盖 | 同 | 保留 |
| 加载期 pacing 倍率 | 同 | 保留 |
| 没有校验 | 启动全量校验 + report | 新增 |
| 热重载靠重启 | F5 重载 content/ | 新增 |

## 十、附：为什么不用 .tres

| 方案 | 优点 | 不选的理由 |
| --- | --- | --- |
| .tres Resource | 编辑器可视化、类型安全 | 手写困难（subresource 引用语法），mod 制作者无法用文本编辑器改，diff 噪音大 |
| JSON | 通用 | 无注释、无节结构、数组/标量混写更难读 |
| **TBL（自研）** | mod 友好、可 diff、可注释、编辑成本最低 | 需要自己写解析器（约 200 行）+ 自己校验 |

选 TBL。解析器与校验器是**一次性成本**，且这个项目的内容量级（15 机型 / 5 队伍 / 73 角色）不值得为 .tres 的编辑器便利付出 mod 门槛。
