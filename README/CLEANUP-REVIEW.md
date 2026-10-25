# 更新后的冗余检查（2026-10-25）

本次先记录候选，不擅自做额外清理。用户要求先检查再询问。必要的候选发现、来源标签与滚动修复不属于这里的可选清理。

| 项目 | 当前证据 | 建议与验证 |
| --- | --- | --- |
| 1. 未使用的 FeatureVariations 布尔接口 | `GAFontDocument.hasFeatureVariations` 只有 getter；引擎同名 getter 也只被它转发，Sources/Tests 无其他调用。现在直接沿用所有分支的并集，不需要依据此布尔值决定重扫。 | 删除两层声明/getter；保留真实分支解析、并集与 VF 测试。低风险。 |
| 2. 按所有长度分桶的旧任务结构 | `GATextScanModel.updateText:selections:` 从 1 到段长建立空 `GATextScanGroup`；当前只产生单字和完整段落任务。`GATextScanItem` 的批次层仍供更新/复用使用，并非死代码。 | 仅建立实际存在长度的有序桶，保留短任务优先、旧任务优先、单字完成判定和缓存身份；不改成全子串扫描。验证重复文字、编辑中任务、长文本和 GID 种子。中等风险。 |
| 3. 新目录与旧 family 正向查询重复 | `relatedOutputs:` 已覆盖 feature 可达的直接 single/alternate 输出；`discoverContent` / `discoverGlyphIDs` 后面仍逐 feature/lookup 再调用 `family`。但 family 的 alternate 输出反查有独立价值，不能整段删除。 | 将正向查询与反向兄弟选项统一在同一查询入口；保留未编码 alternate 兄弟、语言分支、索引值及 GDEF 过滤。避免反查把自己的字形重新标记为替换结果。中等风险。 |
| 4. 测试接口随产品一起编译 | `shapeText:features:script:language:branch:` 和 `featureSpecifications` 只供 `Tests/GSUBCLI.m` 调用；release 也编译这些 Objective-C 方法。不能假定 dead stripping 会删除可被 runtime 发现的方法。 | 把 CLI 适配放在明确测试构建条件下；保留其共用执行核心、定位、诊断和独立 CoreText oracle。风险较低，但会增加构建条件，收益需看最终二进制。可晚些处理。 |

没有发现生产 Sources 中残留 CTLine/CTRun 扫描或 HarfBuzz 调用。Tests 中的原生排版比较是独立验证工具，应保留。字体程序缓存、每 GID 目录缓存、模型范围绑定缓存承担不同工作，不能只因都叫 cache 就合并。

旧 README 的历史章节仍引用旧方法和旧架构，当前架构位于 GLOSSARY 后部。历史记录不建议批量删除；可以另作一次文档整理，不混入本次代码清理。
