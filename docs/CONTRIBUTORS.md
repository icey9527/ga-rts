# 参与方与署名

| 角色 | 标识 | 说明 |
| --- | --- | --- |
| 项目所有者 / 决策 | icey9527 | 所有 ADR 的最终拍板人 |
| 架构 / 实现 | DeepSeek | 主提交署名 |
| 侦察 / 扫描 | GLM-5.3-Flash (scout) | 以 Co-authored-by 附注 |
| 计划 / 评审 | 按需委派 | planner / reviewer 子代理 |

## 提交署名规则

主实现提交：

```
feat(nav): 实现可视图寻路服务
```

侦察类提交（扫描、清单、调研产出）：

```
docs(model): 补充 scn1 模型面数与材质统计

Co-authored-by: GLM-5.3-Flash (scout) <scout@ga-rts.local>
```

不要在代码实现提交上挂 co-author。
