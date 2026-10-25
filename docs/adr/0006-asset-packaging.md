# ADR-0006 资源打包：可分 PCK + AssetCatalog 间接层

- 状态：已采纳
- 日期：S0

## 背景

用户问：Godot 的资源是嵌进 exe 还是能拆成多个资源文件？模型库放仓库还是放发布页？

事实（Godot 4）：

- 导出时资源默认打包成 `.pck`，可选择"嵌入 PCK"写进 exe，也可输出为独立的 `.pck` 同目录
- 运行时可用 `ProjectSettings.load_resource_pack()` 挂载**额外的** pck
- 因此"本体包 + 高清模型包 + 低配模型包"在技术上完全可行

## 结论

**现在不拆包，但现在必须留好间接层。**

1. S0~S3 期间：所有资产直接放 res://assets/，单一 pck，简单优先
2. 但代码里**不得出现任何资源路径字面量**。一律通过 AssetCatalog 按逻辑 ID 取：
   - AssetCatalog.ship("ou134", lod: int) -> PackedScene
   - AssetCatalog.object("ob1501") -> PackedScene
   理由是以后换画质包 / 加 DLC / 支持 mod 时，业务代码一行不改
3. 发布期（S5）拆包方案：
   - 本体 exe + 本体 pck（几十 MB：代码、UI、低模、音效）
   - 模型资源 pck（高/低两种画质，挂发布页可选下载）
   - 通过 load_resource_pack 挂载，缺包时降级到低模或占位
4. 仓库策略：
   - 原始素材库 F:/godot/model **不入库**
   - 转换产物 assets/models/**/*.glb **入库**（它们是项目资源，且只选部分模型，体积可控）
   - 大二进制超过 ~50 MB 再考虑 git-lfs（已安装 3.7.1）

## 代价

- AssetCatalog 多一层间接，早期看起来是过度设计
- 拆包后需要有"资源缺失降级"的分支

## 影响

scripts/assets/asset_catalog.gd、docs/model-pipeline.md、发布流程
