# ADR-0007 Git 工作流、文档组织、署名约定

- 状态：已采纳
- 日期：S0

## 背景

原 2D 项目最痛的点是维护：MAINTENANCE.md 累积了将近 500 行日期化流水账，
信息只进不出，查一件事要全文搜索。用户明确要求这次"方便维护"。

## 结论

### Git

- 主干开发（main），每个阶段开一条短分支（s0-scaffold / s1-vertical-slice …），合并后删除
- 里程碑打 tag：v0.0.1-s0、v0.1.0-s1 …
- 提交信息用 Conventional Commits：feat / fix / refactor / docs / chore / test / perf
- 每个提交只做一件事；一个提交里混了架构改动和功能改动，一律拆开

### 署名

| 角色 | 署名 |
| --- | --- |
| 主实现 / 架构 | DeepSeek <deepseek@ga-rts.local> |
| 侦察 / 扫描产出 | 以 Co-authored-by 附注：GLM-5.3-Flash (scout) <scout@ga-rts.local> |

规则：纯侦察、纯扫描、纯调研产出的提交，在正文末尾加
`Co-authored-by: GLM-5.3-Flash (scout) <scout@ga-rts.local>`。
代码实现由 DeepSeek 署名，不挂 co-author。

### 文档（用 ADR 替代流水账）

| 文件 | 内容 | 更新频率 |
| --- | --- | --- |
| docs/ARCHITECTURE.md | 架构事实：分层、职责、依赖方向、硬规则 | 极少 |
| docs/adr/NNNN-*.md | 一次决策一个文件，追加式，**永不修改旧 ADR** | 有新决策时 |
| docs/scale-and-units.md | 世界尺度约定，写死 | 极少（改需开 ADR） |
| docs/model-pipeline.md | 模型转换管线，可复现 | 管线变动时 |
| docs/controls.md | 双视图操作映射 | 手感调整时 |
| plans/README.md | 里程碑进度与当前任务 | 每阶段 |
| CHANGELOG.md | 面向使用者的变更 | 每次发版 |

**禁止**再出现按日期追加的维护日志。要记录"为什么改"，就写 ADR；要记录"改了什么"，就看 git log 和 CHANGELOG。

### 单测

模拟层不依赖节点（scripts/core、scripts/battle、scripts/systems 全是 RefCounted + Vector3 数学），
因此导航、移动积分、命令仲裁都能用 gdUnit4 纯单测覆盖，不需要起场景。

这条是"以后好维护"的最大杠杆：改手感时跑一遍单测就知道有没有踩坏别的。

## 代价

- 前期写文档要花时间
- ADR 数量会累积，需要一个索引（plans/README.md 里维护）

## 影响

全项目
