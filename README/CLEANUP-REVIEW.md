# 更新后的冗余检查（2026-10-25）

用户已选择“四项都清理”，以下四项均已完成。最初的候选发现、来源标签与滚动修复保存在前一提交 a031fc2；本次单独提交清理。

| 项目 | 当前证据 | 建议与验证 |
| --- | --- | --- |
| 1. 未使用的 FeatureVariations 布尔接口 | `GAFontDocument.hasFeatureVariations` 只有 getter；引擎同名 getter 也只被它转发，Sources/Tests 无其他调用。现在直接沿用所有分支的并集，不需要依据此布尔值决定重扫。 | 删除两层声明/getter；保留真实分支解析、并集与 VF 测试。低风险。 |
| 2. 按所有长度分桶的旧任务结构 | `GATextScanModel.updateText:selections:` 从 1 到段长建立空 `GATextScanGroup`；当前只产生单字和完整段落任务。`GATextScanItem` 的批次层仍供更新/复用使用，并非死代码。 | 仅建立实际存在长度的有序桶，保留短任务优先、旧任务优先、单字完成判定和缓存身份；不改成全子串扫描。验证重复文字、编辑中任务、长文本和 GID 种子。中等风险。 |
| 3. 新目录与旧 family 正向查询重复 | `relatedOutputs:` 已覆盖 feature 可达的直接 single/alternate 输出；`discoverContent` / `discoverGlyphIDs` 后面仍逐 feature/lookup 再调用 `family`。但 family 的 alternate 输出反查有独立价值，不能整段删除。 | 将正向查询与反向兄弟选项统一在同一查询入口；保留未编码 alternate 兄弟、语言分支、索引值及 GDEF 过滤。避免反查把自己的字形重新标记为替换结果。中等风险。 |
| 4. 测试接口随产品一起编译 | `shapeText:features:script:language:branch:` 和 `featureSpecifications` 只供 `Tests/GSUBCLI.m` 调用；release 也编译这些 Objective-C 方法。不能假定 dead stripping 会删除可被 runtime 发现的方法。 | 把 CLI 适配放在明确测试构建条件下；保留其共用执行核心、定位、诊断和独立 CoreText oracle。风险较低，但会增加构建条件，收益需看最终二进制。可晚些处理。 |

没有发现生产 Sources 中残留 CTLine/CTRun 扫描或 HarfBuzz 调用。Tests 中的原生排版比较是独立验证工具，应保留。字体程序缓存、每 GID 目录缓存、模型范围绑定缓存承担不同工作，不能只因都叫 cache 就合并。

旧 README 的历史章节仍引用旧方法和旧架构，当前架构位于 GLOSSARY 后部。历史记录不建议批量删除；可以另作一次文档整理，不混入本次代码清理。


## 完成结果

1. 删除 `GAFontDocument` 和 `GASubstitutionEngine` 的 `hasFeatureVariations` 两层接口；VF 分支解析和所有条件候选并集保留。
2. 调度器只建立实际所需长度的分组并升序排列。10,000 字的单段只建立 1 和 10,000 两个桶；编辑仍保留进行中对象/旧批次优先，段落缓存复用不变。
3. 移除 `OpenType::family` 及 facade 的逐 feature/lookup 重复遍历。直接输出、未编码 alternate 兄弟的反查统一到 `relatedSubstitutions` / `relatedOutputs:` 及每 GID 缓存；明确标记 directFamily，使默认 shaping 后的查询不会误作任意上下文传递闭包。反查仍只作用于 feature 根的 alternate 索引，并检查原始输入的 GDEF 过滤、保留 alternate 索引且排除自身。
4. `featureSpecifications` / `shapeText:...` 和对应 AAT source-name 适配只在 `GA_FONT_LAYOUT_TESTING=1` 中编译。CLI/sanitizer 显式使用 test 构建及独立物件目录；release 默认为 0。编译配置指纹防止同一物件目录切换模式时复用旧物件；失败的配置转换不会留下有效旧指纹。最终两个架构均未包含上述 Objective-C selectors；CLI 保留测试接口。

清理前后 129 组 fixture、字面种子和真实字体查询无候选/来源丢失。128 组完全一致；另一组 alternate.ttf 多 GID 文本种子 [9,19] 新增 [9,18] 兄弟候选（保留前缀），与字面 GID 查询一致，已补回归测试。

CLI 验证现为 352 个替换/资源断言、373 个布局断言、52 个模型断言、7 个显示数据断言、31,755 个 core checks/24,731 次变异执行；ASan/UBSan 103 个字体通过。构建模式还验证了同一物件目录 release → test → release，最终产物检查入口为 `python3 Tests/check-release.py`。没有运行 GUI、安装或 ZIP 解压验证。
