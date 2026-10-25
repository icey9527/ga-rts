# ADR-0010 资源包用 .dat 后缀，可多包挂载

- 状态：已采纳
- 日期：S0
- 部分取代：ADR-0006 里的打包命名部分

## 背景

用户："发布的时候后缀名记得有 .dat，不咋喜欢 pck。"

## 查证（本机 Godot 4.7.2 --doctool）

| API | 签名 |
| --- | --- |
| ProjectSettings.load_resource_pack | `(pack: String, replace_files: bool = true, offset: int = 0) -> bool` |
| PCKPacker.pck_start | `(pck_path: String)` |

两个接口都只接受**路径字符串**，文档中没有任何扩展名约束。
Godot 判定资源包靠文件头魔数（GDPC），不靠后缀。

## 结论

1. 导出时把包名直接写成 `ga_base.dat`、`ga_content.dat` 等（或导出后重命名）
2. 运行时用 `ProjectSettings.load_resource_pack("res://ga_content.dat")` 或绝对路径加载
3. 挂载顺序 = 覆盖优先级（后加载覆盖先加载），写在 content/base.tbl 的 [mounts] 节

## 包划分（S5 发布期实施，现在不分）

| 包 | 内容 | 发布方式 |
| --- | --- | --- |
| ga_base.dat | 代码、UI、音效、低配资源 | 与 exe 一起 |
| ga_models.dat | SB 舰船/物体/特效模型 + 贴图 | 可选下载 |
| ga_hd.dat | 高分辨率贴图（若做） | 可选下载 |

## 待验证

导出后 `load_resource_pack` 对非 .pck 后缀的实际行为，需要在 S0.5 做一次冒烟测试：
用 PCKPacker 生成 .dat，再 load_resource_pack 读回来，确认返回 true 且能取到资源。
若失败，退回"导出 .pck 后重命名 + 加载"，行为等价。

## 影响

docs/ARCHITECTURE.md 的 AssetCatalog 段、S5 发布流程、content/base.tbl 的 [mounts]
