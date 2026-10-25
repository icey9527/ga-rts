# ADR-0008 数据注册表：单一入口 base.tbl + 目录即 ID + 资产引用表

- 状态：已采纳
- 日期：S0
- 取代：无（新增）

## 背景

用户要求：
1. 资产名（模型名、贴图名、音频名）不要写死在代码里，不好维护
2. 模块化：像原 Love2D 版那样，往队伍里加新角色、加新队伍不用改代码
3. 参考《银河天使》：游戏里只写死一个 ga_base.tbl，里面列键，每个键指向一个 TBL，那些 TBL 再去引用资产

原 Love2D 版的 TBL 系统（core/tbl.lua）已验证过核心思路，但格式能力弱：
两层扁平、无嵌套、无引用、无校验，`[weapon.*]` 前缀展开靠调用方手工处理，
`se.tbl` 里数组混键值也要靠加载器补锅。

## 选项

1. Godot 原生 .tres Resource —— 编辑器可视化、类型安全
2. JSON —— 通用、无注释
3. **自研 TBL 文本格式**（沿用原版语法 + 补三点） + 单一入口 base.tbl

## 结论

选 3。

- **代码库里只有一个写死的路径**：res://content/base.tbl
- base.tbl 定义：类别表（每类 → 扫描目录 + manifest 文件名）、根目录优先级、附加包挂载列表
- **目录名即 ID**：content/units/fighter/ → ID 就是 fighter。注册表不列 ID，运行时扫描自动发现。
  这条沿用原版拍板过的决定（"chara.tbl 里声明 ID 是脱裤子放屁"）
- **资产引用集中**：content/assets/assets.tbl 里把逻辑名映射到路径，代码只认逻辑名
- **覆盖链 4 级**：附加包 > 本体 > 皮肤变体 > 占位
- **启动全量校验**并输出 registry_report.txt
- TBL 格式在 Lua 版基础上补：点号分层、类型标注、可选 base 继承

## 代价

- 要自己写 TBL 解析器（约 200 行）+ 校验器
- 放弃 .tres 的编辑器可视化（换来 mod 可直接用文本编辑器改）
- 目录扫描在导出后仍然可用（DirAccess 读 pck 内路径有效），但需要验证

## 放弃 .tres 的理由

.tres 的 subresource 引用语法手写困难、diff 噪音大、mod 作者无法用记事本改。
本作内容量级（15 机型 / 5 队伍 / 73 角色）不值得为编辑器便利牺牲 mod 门槛。

## 影响

docs/data-registry.md、scripts/core/registry.gd、scripts/core/tbl.gd、scripts/assets/、content/
