# Glyph Atlas — GLOSSARY

> **活文档。**本副本是 2026-10-25 的独立 GSUB/AAT 实验；用户已授权完整重构与 CLI 验证，无需逐次弹窗。下方历史段落若与文末实验记录冲突，以实验记录为准。

> 产品行为、决策和测量看 `PRODUCT-LOG.md`；协作方式看 `COLLABORATION-NOTES.md`。

约定：

- 代码符号相对 `Sources/`；`Class.method` 为实例方法，`Class.+method` 为类方法，`private` 表示实现文件内的方法/属性。
- 布局坐标一律为**点（pt）**；字体内部数值为**设计单位（font units）**，换算为 `units × size / upem`。
- `GA` 前缀为本项目命名空间。
- 同一概念只保留一个主术语；其他常见说法在第 12 节列出，避免误解。

## 0. 架构速查

```
侧栏输入（attributedText）
  │
  ├─ GAMainWindowController.scheduleAnalysis
  │    ├─ selectionRunsInAttributedText:didChange:
  │    ├─ GATextScanModel.updateText:
  │    │    ├─ rebuildGroups
  │    │    │    ├─ GAGroupsForText()
  │    │    │    └─ content → [1 字组 index]
  │    │    ├─ desiredSubitems（单字 + 多字 context）
  │    │    ├─ 缓存/旧 pending 对账
  │    │    ├─ 缓存命中按索引 apply
  │    │    └─ notify → textScanModelDidUpdate:
  │    ├─ publishScanDisplayWithSelections:text:
  │    │    ├─ buildDisplayGroupsFromBaseGroups:text:selections:document:
  │    │    ├─ GASidebarViewController.setGroups:/applyStreamedGroups:
  │    │    └─ GADetailViewController.setMultiText:groups:
  │    └─ runScanLoop
  │         ├─ scanModel.startNextSubitem
  │         ├─ analysisQueue: GAFontDocument.rawScanContent:
  │         └─ main: scanModel.completeSubitem:result:
  │              ├─ cache[content] = raw
  │              ├─ 单字：按 content 索引分发给所有同字组
  │              ├─ 多字：apply 到对应目标组
  │              ├─ publish
  │              └─ runScanLoop（下一子项）
  │
  └─ 侧栏 pending（追加/激活）→ 下一次快照解析 → 选中 → 整组滚动 → notify
```

要点：

1. **content 缓存与 range 无关**：`GAScanCandidate.sourceRange` 只带相对 content 的 UTF-16 range，不带输入框绝对位置。
2. **`GAGlyphVariant` 与 range 绑定**：只在 `applyRawResult:` 时按当前 range 创建；同一 content 可在多个位置各 apply 一次。
3. **显示组 = 模型组 + 选择组 + 组合组**；组合组按“最后一个源字符之后”插入。
4. **扫描只处理缺失 content**：旧 pending 保留，新缺失项追加；不重扫缓存内容。
5. **UI 在 main，raw scan 在 analysisQueue**；首次 `setGroups:`，后续 `applyStreamedGroups:`；多字重建由单字完成 + seed 签名驱动。

## 1. 数据模型

| 中文      | English             | 说明                                                                              | 代码符号                                                    |
| ------- | ------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------- |
| 字体文档    | font document       | 已载入字体的查询入口，持有 descriptor、font、`_gsub`、settings                                  | `GAFontDocument`（`GAFontEngine.h`）                      |
| 字体箱     | font box            | 持有 `CTFontRef` 的轻量 ARC 包装                                                       | `GAFontBox`                                             |
| 字形变体    | glyph variant       | 一次 shaping 产生的字形组合，可含多 GID/连字，带 range                                           | `GAGlyphVariant`                                        |
| 字符组     | character group     | 文本中一个合成字符或一个显示组，携带全部候选变体                                                        | `GACharacterGroup`                                      |
| 字形选择    | glyph selection     | 一段替换运行的持久元数据（不含文本偏移）                                                            | `GAGlyphSelection`                                      |
| 全字条目    | all-glyph entry     | 全字视图一行：GID 与 Unicode 标量                                                         | `GAAllGlyphEntry`                                       |
| 行项      | row item            | 侧栏中“字符组 + 变体”的统一行模型                                                             | `GARowItem`（`GAGlyphViews.h`）                           |
| 字形键     | glyph key           | 变体的稳定标识（GID 列表，逗号连接）                                                            | `GAGlyphVariant.glyphKey`                               |
| 扫描子项    | scan subitem        | 一个待扫/扫描中/已完成的 context；带 range/start                                             | `GATextScanSubitem`                                     |
| 扫描项     | scan item           | 一次文字变动产生的一批工作                                                                   | `GATextScanItem`                                        |
| 扫描组     | scan group          | 同一字数的全部项；不是 `GACharacterGroup`                                                  | `GATextScanGroup`                                       |
| 扫描模型    | text scan model     | 理想集、缓存、队列、对账、1 字组索引与发布                                                          | `GATextScanModel`                                       |
| 子项状态    | subitem state       | pending / scanning / completed                                                  | `GATextScanSubitemState`                                |
| raw 候选  | raw candidate       | 与 range 无关的候选：glyphIDs/positions/sources/base/ligature/targetOffset/sourceRange | `GAScanCandidate`                                       |
| raw 结果  | raw scan result     | 一个 content 的候选列表                                                                | `GARawScanResult`                                       |
| 内容      | content             | 缓存键：一个合成字符或连续上下文的子串                                                             | `GATextScanSubitem.content`                             |
| 内容缓存    | content cache       | `content → GARawScanResult`，与 range 无关                                          | `GATextScanModel._cache`、`rawScanContent:`              |
| 内容索引    | content index       | `content → [1 字组 index]`，用于 O(k) 分发                                             | `GATextScanModel._singleGroupIndicesByContent`（private） |
| 理想集     | desired set         | 当前文本的全部连续 context，不跨换行、无长度上限                                                    | `desiredSubitems`                                       |
| 对账      | reconcile           | 理想集与缓存/旧 pending 比对，保留旧项、移除失效、追加新项                                              | `updateText:`                                           |
| 旧项 / 新项 | old item / new item | 旧未完成项优先；新缺失项按组追加在旧项之后                                                           | `GATextScanGroup.items` 数组顺序                            |
| 应用      | apply               | 把 raw 候选按当前 range 建成 `GAGlyphVariant`                                           | `applyRawResult:contentRange:startGroupIndex:groups:`   |
| 组合组     | combination group   | 跨多个字符的替换结果（连字/上下文），只显示、不替换源文本                                                   | `GACharacterGroup.insertedLigature`                     |
| 基础变体    | base variant        | 未应用替换特性的原始字形                                                                    | `GAGlyphVariant.isBase`                                 |
| 特性来源    | feature sources     | 产生变体的 OpenType tag/value（如 `liga`、`aalt 1`）                                     | `GAGlyphVariant.featureSources`                         |
| 目标偏移    | target offset       | 候选目标组在 content 内的相对合成字符索引                                                       | `GAScanCandidate.targetOffset`                          |
| 相对源范围   | source range        | 候选 cluster 相对 content 的 UTF-16 范围                                               | `GAScanCandidate.sourceRange`                           |
| 实际候选    | actual candidate    | 基础字体 shaping 得到的候选（source 记为 `actual`）                                          | `addRawClusters:...`                                    |

## 2. 字体与 CoreText

| 中文              | English                   | 说明                                     | 代码 / API                                                                  |
| --------------- | ------------------------- | -------------------------------------- | ------------------------------------------------------------------------- |
| 字体文件            | font file                 | ttf/otf/ttc/otc/dfont/woff/woff2       | `GAFontURLIsFont`、`CTFontManagerCreateFontDescriptorsFromURL`             |
| 字体描述符           | font descriptor           | 字体面、变化轴、feature 配置的查询对象                | `CTFontDescriptorRef`、`CTFontDescriptorCreateCopyWithAttributes`          |
| 字体面             | face                      | 文件/集合中的一套具体样式                          | descriptor 数组                                                             |
| 字体集合            | font collection           | TTC/OTC 中多个 face                       | `CTFontManagerCreateFontDescriptorsFromURL`                               |
| 可变字体            | variable font             | 由 `fvar` 轴控制的字体                        | `CTFontCopyVariationAxes`、`CTFontCopyVariation`                           |
| 变化轴             | variation axis            | `wght`、`opsz`、`GRAD` 等                 | `kCTFontVariationAxisIdentifierKey`、`kCTFontVariationAxisDefaultValueKey` |
| 命名实例            | named instance            | 预设的 variation 坐标                       | `CTFontCopyVariation`、`CTFontCopyFullName`                                |
| 默认实例            | default instance          | 各轴默认坐标                                 | 同上                                                                        |
| 字体全名            | full name                 | 菜单/窗口标题/侧栏使用                           | `CTFontCopyFullName`                                                      |
| PostScript 名    | PostScript name           | 判断 run 是否来自当前字体                        | `CTFontCopyPostScriptName`                                                |
| 设计单位            | units per em (upem)       | 通常 1000/2048；绘制按 200pt shaping 坐标换算    | `CTFontGetUnitsPerEm`、`GAFontShapingSize`（200）                            |
| 字体匹配            | font matching             | 用 PostScript name 拒绝 fallback run      | `GAFontsMatch`（private）                                                   |
| 字体 fallback     | font fallback             | CoreText 自动借字体；其 GID 不能当当前字体 GID       | 空 cascade list + run 过滤                                                   |
| 字形 ID           | glyph ID / GID            | 字体内部 glyph index                       | `CGGlyph`、`GAGlyphVariant.glyphIDs`                                       |
| CID             | CID                       | CFF 的字符 ID；项目不做 CID 转换                 | —                                                                         |
| 字形名称            | glyph name                | 字体提供的名称，或 `GID n`                      | `CTFontCopyNameForGlyph`、`GAGlyphVariant.glyphName`                       |
| 合成名称            | synthetic glyph name      | `gidNNN`、`uniXXXX.N`、`uniXXXX_uXXXX` 等 | `GAGlyphNameLooksSynthetic`（private）                                      |
| `.notdef` / 缺字  | .notdef / missing glyph   | GID 0；base 无字形时的缺字表示                   | `shapeString:...` 的 GID 0 回退                                              |
| Unicode 映射      | Unicode map               | GID → Unicode scalars                  | `CTFontCopyCharacterSet`、`CTFontGetGlyphsForCharacters`、`unicodeMap`      |
| Unicode 标量      | Unicode scalar            | 码位；一个字形可映射多个                           | `GAGlyphVariant.unicodeScalars`、`GAStringFromUnicodeScalars()`            |
| 码位名称            | Unicode name              | 系统 ICU 名称                              | `GAUnicodeNameForScalar()`                                                |
| GSUB            | Glyph Substitution Table  | 字形替代表                                  | `CTFontCopyTable(kCTFontTableGSUB)`                                       |
| FeatureList     | feature list              | 特性 tag 和 lookup 索引                     | `GAOTProgram.branchFeatures`（private）                                                 |
| AAT             | Apple Advanced Typography | feature type/selector                  | `CTFontCopyFeatures`、`kCTFontFeatureTypeIdentifierKey`                    |
| `vert` / `vrt2` | vertical forms            | 竖排字形替换                                 | `GAVerticalSubstituteForGlyph`（private）                                   |
| `hmtx`          | horizontal metrics        | 水平 advance / LSB                       | `CTFontCopyTable`、`CGFontGetGlyphAdvances`                                |
| `vmtx` / `vhea` | vertical metrics          | 垂直 advance / TSB                       | `CTFontCopyTable`、`variantHasVerticalMetrics:`                            |
| `hhea` / `OS/2` | horizontal header / OS/2  | ascent/descent/lineGap 等               | `CTFontGetAscent/Descent/Leading`                                         |
| `fvar` / `HVAR` | variations                | 轴/水平 advance 增量                        | CoreText/CGFont                                                           |
| `trak`          | tracking table            | 随字号变化的 tracking                        | `CTFontGetAdvancesForGlyphs` 应用；`CGFontGetGlyphAdvances` 不应用              |
| 水平 advance      | horizontal advance        | 水平步进宽度                                 | `advanceInFontUnitsForVariant:`                                           |
| 垂直 advance      | vertical advance          | 垂直步进高度；无 vmtx 时回退 ascent+descent       | 同上                                                                        |
| 上升部 / 下降部       | ascent / descent          | 基线上下高度                                 | `CTFontGetAscent/Descent`                                                 |
| 基线              | baseline                  | 字形绘制参考线                                | `baselineUnits`                                                           |
| 左边距             | left side bearing (LSB)   | 墨迹左缘到原点                                | `CGRectGetMinX(inkBox)`                                                   |
| 竖排顶边距           | top side bearing (TSB)    | vmtx 顶部留白                              | `verticalTopSideBearingForVariant:`                                       |
| 墨迹框             | ink bounds                | 轮廓外接框，可为空                              | `CTFontGetBoundingRectsForGlyphs`、`inkBoundsForVariant:`                  |
| 字身框             | em box / advance box      | 单字页面：宽=advance，高=ascent+descent        | `GAGlyphCanvasView` 的 `page`                                              |
| shaping 字号      | shaping size              | 变体分析/整形字号（200）                         | `GAFontShapingSize`                                                       |

### 2.1 可载入的字体格式（2026-10-23 实测，macOS 14.8.7）

`GAFontURLIsFont` / 打开面板先按 UTI 过滤，能否真正打开由 `CTFontManagerCreateFontDescriptorsFromURL` 决定。

| 扩展名 | UTI | 实测结果 |
| --- | --- | --- |
| `.ttf` | `public.truetype-ttf-font` | 可读 |
| `.otf` | `public.opentype-font` | 可读，CFF 与 TrueType 轮廓均可 |
| `.ttc` | `public.truetype-collection-font` | 可读；多 face 弹 “Choose Font Style”（`Helvetica.ttc` 6 个） |
| `.otc` | `public.opentype-collection-font` | 可读 |
| `.dfont` | `com.apple.truetype-datafork-suitcase-font` | 可读 |
| `.woff` | `org.w3c.woff` | 可读，TrueType/CFF 两种 flavor 实测均通过 |
| `.woff2` | `org.w3c.woff2` | 可读 |

- `woff` / `woff2` 不 conform 到 `public.font`，所以 `GAFontContentTypes()` 与 `Info.plist` 都显式列出这两个 UTI。
- `public.font` 还包含 Type 1 `.pfa` / `.pfb`：打开面板会放行，但 CoreText 返回 0 个 descriptor，app 报 “Cannot Open Font”（`.pfa` 实测；`.pfb` 同属 Type 1）。
- 过滤只看文件 UTI（通常由扩展名决定），不做 magic-byte 嗅探：`Geneva.ttf` 改名 `.bin` 后 CoreText 仍能读，但 `GAFontURLIsFont` 返回 NO。
- WOFF/WOFF2 依赖系统 CoreText 版本；最低目标 macOS 12.0 未实机验证，以上为 14.8.7 结果。
- `Info.plist` 的 `public.truetype-ttc-font` 在系统里不存在（`UTType typeWithIdentifier:` 返回 nil）；实际生效的是 `public.truetype-collection-font`。不影响打开，是死声明。

## 3. 整形、变体与扫描

### 3.1 文本切分

| 中文         | English                 | 说明                                                     | 代码符号                                |
| ---------- | ----------------------- | ------------------------------------------------------ | ----------------------------------- |
| 合成字符组      | composed character      | 按 `NSStringEnumerationByComposedCharacterSequences` 切分 | `GAGroupsForText()`                 |
| 单字组        | single-character group  | 一个合成字符，扫描 length = 1                                   | `GATextScanSubitem.length == 1`     |
| 多字 context | multi-character context | 连续 2..n 个合成字符，不跨换行                                     | `desiredSubitems`                   |
| 字符范围       | text range              | 组在整段文本中的 UTF-16 范围                                     | `GACharacterGroup.textRange`        |
| 源文本范围      | source text range       | 连字/替换覆盖的源字符范围                                          | `GAGlyphVariant.sourceTextRange`    |
| 硬换行        | hard line break         | 模型 U+000A；输入框 U+23CE 标记；扫描不跨行                          | `GALineBreakAttributeName`（private） |

### 3.2 变体发现

| 中文         | English               | 说明                                                | 代码符号                                                                 |
| ---------- | --------------------- | ------------------------------------------------- | -------------------------------------------------------------------- |
| shaping    | shaping               | 文本 + 字体 → CTRun → GID 序列                          | `CTLineCreateWithAttributedString`、`CTLineGetGlyphRuns`              |
| 单字扫描       | per-character scan    | 单字 content → base + GSUB alternates + settings    | `characterVariantsForContent:`、`rawSingleCharacterResultForContent:` |
| 上下文扫描      | context scan          | 多字 content → base/feature clusters，按 cluster 目标归组 | `rawContextResultForContent:groups:`、`addRawClusters:...`            |
| GSUB 直接替换  | direct GSUB alternate | 从 GSUB 表直接取 single/alternate                      | `GASubstitutionEngine.discoverText:/discoverGlyphIDs:`                                   |
| 单字形替换      | SingleSubst           | GSUB lookup type 1，format 1/2                     | `FontLayout/GAOpenType` + `GASubstitution` + family index                                      |
| 备用字形替换     | AlternateSubst        | GSUB lookup type 3                                | `FontLayout/GAOpenType` + `GASubstitution` + family index                                     |
| 整串 cluster | whole-text cluster    | 一次 shaping 的连续 cluster；start/end/glyphs           | `GAWholeTextClusters`（private）                                       |
| 组跨度        | group span            | cluster 覆盖的合成字符组范围                                | `GAGroupSpanForCluster`（private）                                     |
| 特性设置       | feature setting       | 一个 AAT/OpenType feature 的字体箱和来源                   | `GAFeatureSetting`（private）                                          |
| 实际候选       | actual candidate      | 基础字体的 cluster，source = `actual`                   | `addRawClusters:...`                                                 |
| 连字 / 上下文替换 | ligature / contextual | cluster 跨多个合成字符                                   | `GAScanCandidate.ligature`、`sourceRange`                             |
| 候选去重       | candidate dedup       | raw 内按 `(target, glyphs)` 去重并合并 sources           | `addRawClusters:...`                                                 |
| 特性来源       | feature source        | `sourceName → tag → key`；AAT 不标                   | `featureSources`                                                     |

### 3.3 扫描模型（当前）

| 中文        | English              | 说明                                                    | 代码符号                                                            |
| --------- | -------------------- | ----------------------------------------------------- | --------------------------------------------------------------- |
| 更新文本      | update text          | 重建 groups、单字索引、理想集、对账、通知                              | `GATextScanModel.updateText:`（单参数）                              |
| 单字索引      | single-group index   | `content → [group index]`，缓存命中时分发用                    | `_singleGroupIndicesByContent`（private）                         |
| 理想集       | desired set          | 当前文本全部连续 context                                      | `desiredSubitems`                                               |
| 新缺失项      | new missing item     | 无缓存、无旧 pending 的 context                              | `updateText:`、`missingItemByLength`                             |
| 旧 pending | old pending          | 仍有效、未扫完的子项；保留在旧项先扫                                    | `GATextScanSubitem.state`                                       |
| 对账        | reconcile            | 缓存/旧 pending/新理想集三者对齐                                 | `updateText:`                                                   |
| 扫描循环      | scan loop            | 取子项 → raw → 主线程 complete → 下一项                        | `runScanLoop`                                                   |
| 单字完成      | single completion    | 长度 1 只 apply 一次，按 content 索引分发到所有同字组                  | `completeSubitem:result:`、`applySingleCharacterResult:content:` |
| 多字完成      | multi completion     | 按 candidate target 合并到目标组                             | `completeSubitem:result:`、`applySubitem:`                       |
| 单字扫描完成    | single scan complete | 没有长度 1 的 pending 子项即完成；没有组也返回 YES                     | `singleCharacterScanComplete`（`GAMainWindowController` private） |
| 多字重建门槛    | multi rebuild gate   | 文本变化且单字完成，或 seed 签名变化                                 | `shouldUpdateMulti`                                             |
| 清空重置      | clear reset          | 清空文本时重置 `workerLastMultiText/Seeds`                   | `clearScanDisplay`                                              |
| 发布代次      | generation guard     | 旧 generation 不得写回新文本的多字签名/snapshot                    | `workerGeneration`、`publishWorkerSnapshotWithText:...`          |
| 应用 raw    | apply raw            | 目标组 = startGroupIndex + targetOffset；同 key 合并 sources | `applyRawResult:contentRange:startGroupIndex:groups:`           |
| 扫描组列表     | scan groups          | 队列的组/项/子项结构                                           | `scanGroups`                                                    |

### 3.4 单字分发的准确含义

- 单字按 content 去重：`aaaa` 只创建一个 `a` 扫描子项。
- 该子项只覆盖第一个 `a` 的 range。
- 完成后用 `_singleGroupIndicesByContent[@"a"]` 遍历四个 1 字组，把同一个 `GARawScanResult` 合并进各自的 `variants`。
- 这是**内存分发**，不是重新 shaping、不是重新读字体表。
- 当前 `completeSubitem:` 对长度 1 只做一次 apply；`aaaa` 仍得到 4 个变体。
- 所有单字只按 content cache 判断。

## 4. 多字视图（TextKit 2）

| 中文      | English                        | 说明                                                | 代码符号                                                   |
| ------- | ------------------------------ | ------------------------------------------------- | ------------------------------------------------------ |
| 多字视图    | multi-character view           | 一个画布，横排/竖排共用                                      | `GAMultiGlyphView`                                     |
| 文本视图    | text view                      | 实际排版/绘制者；不接收鼠标                                    | `GAMultiTextView`（private）、`NSTextView`                |
| 文本布局管理器 | text layout manager            | TextKit 2 布局入口                                    | `NSTextLayoutManager`                                  |
| 文本容器    | text container                 | 容器尺寸与内边距                                          | `NSTextContainer`、`textContainerInset`                 |
| 容器原点    | text container origin          | 旋转 bounds 下尤其关键                                   | `textContainerOrigin`                                  |
| 布局片段    | layout fragment                | 段落/文本元素布局结果                                       | `NSTextLayoutFragment`                                 |
| 行片段     | line fragment                  | 一行/一列的实际排版矩形                                      | `NSTextLineFragment`                                   |
| 使用边界    | used bounds                    | 文本实际占用范围                                          | `usageBoundsForTextContainer`                          |
| 横排内边距   | horizontal inset               | `textContainerInset = side inset`，frame = page 外扩 | `positionTextView`                                     |
| 竖排零内边距  | vertical zero inset            | frame = pageRect，inset = 0；避免旋转后容器偏移              | `positionTextView`                                     |
| 竖排裁切    | vertical ink clipping          | 竖排墨迹越出页面会被文本视图裁切                                  | `positionTextView`                                     |
| 垂直形式    | vertical forms                 | TextKit 2 按竖排应用 `vert/vrt2`                       | —                                                      |
| 字符朝向    | vertical orientation (UAX #50) | 汉字正立、拉丁/数字旋转                                      | `GAVerticalScalarRotates()`                            |
| 替换种子    | seed                           | 用户选中的无编码替换字形                                      | `GACharacterGroup.seeded`                              |
| 字形信息    | glyph info                     | 源字符 → 指定 GID                                      | `NSGlyphInfo`、`NSGlyphInfoAttributeName`               |
| 基础字符    | base string                    | 种子显示字符；决定朝向/步进/断行                                 | `NSGlyphInfo.glyphInfoWithGlyph:forFont:baseString:`   |
| 基础字符替换  | base substitution              | 竖排：非直立源字符+全宽 GID → 字；直立+窄 GID → A；只改显示副本          | `replacementBaseForOriginal:glyph:font:`               |
| 全宽种子    | full-width seed                | advance == upem 或 字 的 advance                     | `glyphIsFullWidth:font:`                               |
| 竖排引号    | vertical quote                 | 非 seed 引号使用字体 `vert` 输出                           | `verticalQuoteGlyphForGroup:font:`                     |
| 文本缩放    | text scale                     | 32pt × 1.12^n，n = −10…20                          | `GAMultiBaseFontSize`、`GAMultiClampTextScale`（private） |
| 页面      | page                           | 白页矩形；尺寸来自文本布局                                     | `pageRect`、`pageContentSize`                           |
| 视口      | viewport                       | 滚动视图可见尺寸                                          | `viewportSize`                                         |
| 文档尺寸    | document size                  | 视口与页面共同决定的滚动内容尺寸                                  | `documentSize`                                         |
| 缩放      | zoom                           | 键盘/捏合改变 text scale                                | `zoomTextIn/Out`、`resetTextZoom`                       |

## 5. 单字画布与几何

| 中文   | English             | 说明                                    | 代码符号                                             |
| ---- | ------------------- | ------------------------------------- | ------------------------------------------------ |
| 单字画布 | single-glyph canvas | 定义页 + CoreText 自绘                     | `GAGlyphCanvasView`                              |
| 定义页  | definition page     | 字身框对应的白页                              | `page`、`GADrawPage()`                            |
| 页面度量 | page metrics | 页面尺寸、baseline、墨迹（font units）；单字画布用 YES（vmtx），全字/缩略图用 NO（advance × ascent+descent） | `GAGlyphPage`、`GAFontDocument.+pageForVariant:usesVerticalMetrics:` |
| 页面阴影 | page shadow         | 22pt blur / (0,-8) offset；深浅 alpha 手调 | `GADrawPage()`                                   |
| 主视图  | main view           | 最终可见区域；字形只受此限制                        | `self.bounds`、`glyphLimit`                       |
| 内容区  | content rect        | 主视图四周 11% 内缩；页面必须在内                   | `contentGuide`、`GAInsetRectByFraction()`         |
| 边距比例 | side inset fraction | 0…`0.5*(1-1/1.12^22)`                 | `sideInsetFraction`、`GAClampSideInsetFraction()` |
| 默认边距 | default side inset  | 0.1014（page 79.72%）                   | `GACanvasDefaultSideInsetFraction`               |
| 页面占比 | page fraction       | `1 - 2*inset`；键盘缩放按此比例                | `GACanvasPageFractionForMagnification()`         |
| 最大缩放 | maximum scale       | 页面/墨迹约束的线性最大公共 scale                  | `GAMaxScaleForAxis`（private）                     |
| 共同平移 | shared translation  | 页面和字形共用平移                             | `translationForScale`（private）                   |
| 边界余量 | boundary margin     | 字形与主视图之间 1pt                          | `GACanvasBoundaryMargin`                         |
| 缩放微调 | scale epsilon       | 0.999999，防浮点边界空帧                      | `GACanvasScaleEpsilon`                           |
| 缩放步进 | zoom step           | 1.12；10 步 = `1.12^10`                 | `GAGlyphZoomStep`、`GAGlyphZoomStep10`            |
| 墨迹外溢 | ink bleed           | 单字画布允许字形越出页面，不裁剪                      | `layer.masksToBounds`                            |
| 画布背景 | canvas background   | 浅色 #FFF / 深色 #3C3C3C                  | `GACanvasBackgroundColor()`                      |
| 字形前景 | glyph foreground    | 浅色 #222222 / 深色 #EEEEEE               | `GAGlyphForegroundColor()`                       |

## 6. 全字视图

| 中文    | English         | 说明                              | 代码符号                             |
| ----- | --------------- | ------------------------------- | -------------------------------- |
| 全字视图  | all-glyphs view | 所有 GID 的等距网格                    | `GAAllGlyphsView`                |
| 网格    | grid            | 44pt 基准单元格，8pt gap              | `GAAllGlyphsGrid`                |
| 页面居中  | page centring   | 格内居中 advance 宽 × (ascent+descent) 的页面，baseline=descent；不按墨迹居中，不读 vmtx | `GAAllGlyphsGrid.drawRect`、`pageMetrics` |
| 单元格缩放 | cell scale      | 1.12^−10 … 1.12^10              | `GAAllGlyphsClampScale`（private） |
| 揭示    | reveal          | 侧栏选中 GID 时滚动/居中/闪烁              | `revealGlyphID:quick:`           |
| 追加    | append          | 双击编码单元格追加首字符并 pending 选中        | `appendAllGlyphEntry:`           |
| 闪烁    | highlight       | 定位：0.1/0.1/1.0/0.7s；追加：0.2/0.8s | `flashIndex:quick:`              |

页面度量按 GID 惰性计算并缓存；单字画布调用 YES，全字网格调用 NO；字体变化时缓存失效。

## 7. 侧栏、输入与选择

| 中文         | English             | 说明                                                                             | 代码符号                                                                      |
| ---------- | ------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| 输入框        | input field         | `GASearchField`（`NSSearchField` 子类），无放大镜/清除按钮；左右各 9pt 内缩由 `GASearchFieldCell` 固定 | `GASearchField`、`GASearchFieldCell`、`GASidebarViewController.searchField` |
| 字段编辑器      | field editor        | 编辑时的 `NSTextView`                                                              | `currentEditor`、`GASearchFieldEditor`                                     |
| 换行标记       | line-break marker   | 输入框 U+23CE + 自定义属性；模型为 U+000A                                                  | `GALineBreakAttributeName`（private）                                       |
| 纯文本规范化     | plain normalization | 只保留字体、颜色、selection run、换行标记                                                    | `applyPlainAttributesToStorage:fromText:`                                 |
| 选择运行       | selection run       | 属性字符串中的 range + `GAGlyphSelection`                                             | `GAGlyphSelectionAttributeName`                                           |
| 选择组        | selection group     | run 在显示列表中的组表示                                                                 | `groupForSelectionRun:document:`                                          |
| 字形列表       | glyph list          | 字符组/变体/seed 行                                                                  | `NSTableView`、`setGroups:`                                                |
| 流式列表       | streamed list       | 后续快照原地重建，保留选中锚点                                                                | `applyStreamedGroups:`                                                    |
| 变体行        | variant cell        | 缩略图、名称、来源、Unicode 徽章                                                           | `GAVariantCellView`                                                       |
| 缩略图        | thumbnail           | 34pt 图标、32pt/em；按 advance × (ascent+descent) 的页面居中，baseline=descent；墨迹可画到行内边距 | `GAGlyphView`、`pageForVariant:usesVerticalMetrics:NO`                    |
| Unicode 徽章 | Unicode badge       | 16pt 高、3pt gap、4pt 横向 padding                                                  | `GAUnicodeCodesView`、`GAUnicodeBadgeView`                                 |
| pending 选择 | pending selection   | 追加/激活后按 range → 精确 GID → base 行解析                                              | `pendingSelectionGlyphKey`、`rowForPendingSelection`                       |
| pending 等待 | pending wait        | 组/base 未出现：不恢复旧选择、不跳第一                                                         | `setGroups:`、`applyStreamedGroups:`                                       |
| 组滚动        | group scroll        | 组放不下→顶对齐；能放下：顶/底/不动                                                            | `scrollGroupContainingRow:`                                               |
| 手动选择       | manual selection    | 点击行清空 pending；流式快照不覆盖                                                          | `tableViewSelectionDidChange:`                                            |
| 激活         | activate            | Return/双击；编码替换文本，无编码建 run；Shift 时插到自身 source range 右侧（A）                                  | `activateGlyphVariant:inGroup:`                                           |
| Shift 激活   | shift activation    | 触发事件里只有 Shift：把点中字形插到自身 source range 右缘，原字形不动；不选中新项，原选中行保持                                 | `GAModifiersAre(modifiers, Shift)`、`activateRowAtIndex:modifiers:`、`onGlyphShiftActivated`、`insertGlyphVariant:inGroup:` |
| 激活 payload | activation payload  | 有 Unicode → 首个 Unicode 字符（无 run）；无 Unicode → sourceText + run                         | `activationPayloadForVariant:sourceText:selection:`                       |
| 激活收尾      | activation finish   | 普通激活：pending 选择 + 写回文本框 + 手动 `scheduleAnalysis`（内联在 `activateGlyphVariant:`）             | `activateGlyphVariant:inGroup:`                                           |
| Shift 插入写回 | shift insertion publish | 不设 pending 选择；只写回文本框 + 手动 `scheduleAnalysis`，保持原选中行                              | `insertGlyphVariant:inGroup:`                                             |
| 复制编码       | copy encoding       | 复制全部 Unicode 标量                                                                | `copySelectedGlyphEncoding`                                               |
| 列表失活       | inactive dim        | 窗口失活时列表 alpha 0.37                                                             | `setGlyphListDimmed:`                                                     |

### 快捷键

| 操作                    | 快捷键                          |
| --------------------- | ---------------------------- |
| 单字 / 多字 / 全字          | `⌘1` / `⌘2` / `⌘3`           |
| Show Metrics          | `⌘4`                         |
| Vertical              | `⌘5`                         |
| 放大 / 缩小 / Actual Size | `⌘+` / `⌘-` / `⌘0`           |
| Metrics 缩放            | `⌥⌘+` / `⌥⌘-`                |
| 行首 / 行尾               | `⌘←` / `⌘→`（也接受 `⌘↑` / `⌘↓`） |
| 组导航                   | `⌘↑` / `⌘↓`（列表内）             |
| 激活 / 复制               | Return / `⌘C`                |
| Shift 激活                | `Shift+Return` / `Shift+双击`   |

## 8. 窗口、控制器与菜单

| 中文     | English                 | 说明                                  | 代码符号                                                |
| ------ | ----------------------- | ----------------------------------- | --------------------------------------------------- |
| 字体窗口   | font window             | 一个字体一个窗口                            | `GAMainWindowController`                            |
| 主窗口控制器 | window controller       | 菜单、字体载入、扫描接线、选择分发                   | `GAMainWindowController`                            |
| 详情容器   | detail view controller  | 三种视图、布局、缩放                          | `GADetailViewController`                            |
| 侧栏控制器  | sidebar view controller | 输入、列表、pending、滚动                    | `GASidebarViewController`                           |
| 拖放窗口   | drop window             | 接收字体文件拖放                            | `GADropWindow`                                      |
| 字体打开   | open font               | descriptors → face 选择 → 后台载入        | `loadFontAtURL:`、`chooseDescriptorFromDescriptors:` |
| 工具栏字体名 | toolbar font name       | 标题栏左侧字体全名                           | `NSToolbar`、`GATitleToolbar`                        |
| 最近字体   | recent fonts            | 系统 recent documents                 | `NSDocumentController`                              |
| 视图模式   | view mode               | 全字 / 多字 / 单字                        | `GAViewMode`                                        |
| 分栏     | split view              | sidebar + detail，tracking separator | `NSSplitViewController`                             |

窗口：初始 600×400；代码 `window.minSize` 为 600×390；`PRODUCT-LOG.md` 写 600×400，待确认。侧栏初始 200pt，可 200–1000pt。关闭最后窗口不退出。

## 9. 文件、构建与诊断

| 中文        | English           | 说明                           | 代码 / 命令                                              |
| --------- | ----------------- | ---------------------------- | ---------------------------------------------------- |
| 构建        | build             | universal、0 warning、min 12.0；只输出 app | `bash build.sh`                                      |
| Universal | universal binary  | arm64 + x86_64               | `ARCHS="arm64 x86_64"`、`lipo`                        |
| 部署目标      | deployment target | macOS 12.0                   | `-mmacosx-version-min=12.0`、`LSMinimumSystemVersion` |
| Ad-hoc 签名 | ad-hoc signing    | 无证书                          | `codesign --force --deep --sign -`                   |
| 字体 UTI    | font UTType       | 打开/拖放判断                      | `GAFontContentTypes()`、`UTTypeFont`                  |
| 原始表       | raw font table    | 直接读 sfnt 字节                  | `CTFontCopyTable`                                    |
| 诊断工具      | diagnostics       | 字体表/竖排数据测量，不参与编译             | `diagnostics/inspect_font.m`                         |
| 项目根       | project root      | 所有路径相对 `GlyphAtlas/`         | `build.sh`、`README/`、`Sources/`、`dist/`              |

## 10. 关键对象关系

```
GAFontDocument
  ├─ allGlyphEntries
  ├─ rawScanContent:
  │    └─ GARawScanResult
  │         └─ GAScanCandidate
  ├─ applyRawResult:... ──→ GACharacterGroup.variants
  ├─ verticalSubstituteForGlyph:
  └─ inkBounds/advance/vertical metrics

GATextScanModel
  ├─ _groups: [GACharacterGroup]
  ├─ _cache: content → GARawScanResult
  ├─ _singleGroupIndicesByContent: content → [index]
  ├─ _scanGroups: [GATextScanGroup → GATextScanItem → GATextScanSubitem]
  └─ updateText: / startNextSubitem / completeSubitem:

输入框 attributed string
  └─ GAGlyphSelectionAttributeName
       └─ GAGlyphSelection (sourceText / glyphIDs / featureSources / ligature)

buildDisplayGroupsFromBaseGroups:
  source groups
  + selection groups
  + combination groups
  → GASidebarViewController.setGroups:/applyStreamedGroups:
  → GADetailViewController.setMultiText:groups:
```

## 11. 术语歧义与统一写法

这一节是**防误解索引**。同一个东西出现多种说法时，优先用“主术语”；括号里是旧说法/口语，不要在正式讨论里混用。

### 11.1 画布/页面/边距

| 主术语   | 也常被说成                    | 准确含义                            | 不要混淆                    |
| ----- | ------------------------ | ------------------------------- | ----------------------- |
| 单字画布  | 画布、canvas                | 整个 `GAGlyphCanvasView`          | 不是页面                    |
| 主视图   | 可见区、视图                   | 用户实际看到的 bounds；字形只受它限制          | 不是 11% 内容区              |
| 内容区   | content guide、11%        | 主视图四周内缩 11% 的约束区；页面必须在内         | 不是页面本身                  |
| 页面    | 白页、definition page       | 字身框对应的白色矩形；有阴影                  | 不是整个画布                  |
| 边距比例  | inset、side inset、留白      | `sideInsetFraction`，页面四周相对视口的比例 | 不是 `contentGuide` 的 11% |
| 文本内边距 | inset、textContainerInset | 多字视图 TextKit 的容器内边距             | 不是页面边距                  |

### 11.2 字体/字形

| 主术语     | 也常被说成                    | 准确含义                       | 不要混淆               |
| ------- | ------------------------ | -------------------------- | ------------------ |
| 字体文档    | font、document、字体         | `GAFontDocument`，查询入口      | 不是 `CTFontRef`     |
| 字体箱     | font box、fontBox         | `GAFontBox`，持有 `CTFontRef` | 不是字身框              |
| 字身框     | em box、advance box、字面框   | 单字页面的度量矩形                  | 不是 `GAFontBox`     |
| advance | 步进、字宽、宽度                 | 排版的步进量                     | 不是墨迹宽度             |
| 墨迹宽度    | ink width、bbox width     | 轮廓外接框宽度                    | 不是 advance         |
| 字形宽度    | 字宽                       | **歧义**：说清楚是 advance 还是 ink | 不要单独用“字宽”          |
| LSB     | left side bearing、左边距    | 墨迹左缘到原点                    | 不是页面 side inset    |
| TSB     | top side bearing、上边距     | vmtx 顶部留白                  | 不是页面 side inset    |
| 缺字      | missing、.notdef、fallback | GID 0 或字体无字形               | 不是 fallback 字体 GID |
| 种子      | seed、替换字、选中字形            | 用户激活的无编码替换                 | 不是 base variant    |

### 11.3 扫描/数据

| 主术语   | 也常被说成                      | 准确含义                               | 不要混淆                 |
| ----- | -------------------------- | ---------------------------------- | -------------------- |
| 扫描    | scan、raw scan、重新读字         | `rawScanContent:`/`GASubstitutionEngine` | 不是内存 apply           |
| 遍历    | loop、遍历组                   | 遍历内存数组                             | 不是重新 shaping         |
| 分发    | apply、应用、合并                | 把已算好的 candidate 合并进组               | 不是重新扫描               |
| cache | 缓存、content cache           | `content → GARawScanResult`        | 不是 desired set       |
| 理想集   | desired set、待扫集            | 当前文本全部 context                     | 不是 cache             |
| 内容    | content                    | 子串，缓存键                             | 不是 range，不是 GID key  |
| 字形键   | glyph key、key              | GID 序列字符串                          | 不是 content           |
| 字符组   | group、GACharacterGroup     | 显示/文本的合成字符组                        | 不是 `GATextScanGroup` |
| 扫描组   | scan group、GATextScanGroup | 按字数分的扫描队列组                         | 不是字符组                |
| 扫描子项  | subitem                    | 一个待扫 context                       | 不是变体                 |
| 候选    | candidate、raw 候选           | range 无关的 raw 结果                   | 不是 `GAGlyphVariant`  |
| 变体    | variant、glyph variant      | range-bound 的显示字形组合                | 不是 raw candidate     |
| 1 字组  | 单字组、single group           | 一个合成字符的字符组                         | 不是单字扫描子项             |
| 组合组   | 连字组、context group          | 跨多字符的显示组                           | 不是字符组/选择组            |
| 发布    | publish、推送                 | 把 snapshot 发到 UI                   | 不是 apply             |
| 完成    | complete、completed         | 子项状态/单字扫描无 pending                 | 不是“没有组”              |

### 11.4 选择/UI

| 主术语             | 也常被说成         | 准确含义                               | 不要混淆               |
| --------------- | ------------- | ---------------------------------- | ------------------ |
| selection run   | 选择运行、替换 run   | 属性字符串里的 range + `GAGlyphSelection` | 不是 selection group |
| selection group | 选择组           | run 在显示列表中的组                       | 不是 source group    |
| source group    | 源组、原文字组       | 未被 run 覆盖的文本组                      | 不是选择组              |
| 组合组             | 连字组、插入组       | 只浏览的跨字符结果                          | 不是源组               |
| pending 选择      | pending、待选中   | 追加/激活后等待解析的选择                      | 不是普通选中             |
| Shift 激活        | shift 插入、shift 双击、shift+enter | 触发事件里只有 Shift，在 source range 右缘插入 | 不是普通激活（原地替换）       |
| 字形列表            | 侧栏、table、列表   | `NSTableView` 的变体行                 | 不是全字网格             |
| 全字视图            | all glyphs、网格 | 所有 GID 的集合                         | 不是侧栏列表             |
| 页面              | page、白页       | 定义页                                | 不是窗口/画布            |
| 文档尺寸            | documentSize  | 滚动内容尺寸                             | 不是页面尺寸/视口          |

### 11.5 缩放/视图

| 主术语               | 也常被说成     | 准确含义               | 不要混淆                 |
| ----------------- | --------- | ------------------ | -------------------- |
| textScale         | 多字缩放、字号   | 多字视图 32pt × 1.12^n | 不是页面 inset           |
| cellScale         | 全字缩放、格子大小 | 全字视图 44pt × scale  | 不是字体字号               |
| sideInsetFraction | 页面缩放、边距   | 单字/多字页面留白          | 不是文本 scale           |
| zoom              | 放大/缩小     | 键盘/捏合操作            | 具体改哪个 scale 要说明      |
| 页面                | page      | 定义页                | 不是 viewport/document |

## 12. 已知限制

- 初次完整扫描是 O(n²) 个 context；完整扫描是产品要求，但长文本仍慢。
- 缓存按 content 保留，长文本下内存会增长；上限是后续工作。
- 全字视图的页面度量缓存按 GID 分配（约 56B/字；62k 字形约 3.5MB），换字体时释放。
- 多字视图竖排墨迹越出页面会被裁切；横排保留外扩。
- 多字视图组合组只浏览，不替换源文本。
- 多 GID 种子已在本实验中修复：显示副本展开所有组件，UTF-16 点击索引映射回原文。
- 侧栏整组滚动在组比可视区高时只保证顶部。
- `setGroups:` / `applyStreamedGroups:` 未合并：fallback、notify、pending 行为不同。
- `setTextScale:` 在值未变时仍会 rebuild；当前未加保护（用户暂不动）。
- 窗口最小尺寸文档冲突：`PRODUCT-LOG.md` 600×400，代码 `minSize` 600×390、初始 600×400，待确认。
- 搜索框左右各 9pt 内缩由 `GASearchFieldCell` override 三个 rect 实现以兼容 macOS 26+。
- Shift 激活锚点是被点行自己的 source range 右缘；同一源组连续插入会倒序。
- Shift 激活对有 Unicode 的字形只插普通字符、不建 run，点中的 GID 不固定；插入后不选中新项，原选中行保持。
- 修饰键判断统一由 `GAModifiersAre(modifiers, expected)` 完成：只看 Command/Shift/Option/Control；Caps Lock、Fn、小键盘、设备位不参与。
- Shift 用触发事件的 `modifierFlags` 判断；`keyDown:` 与 `tableDoubleClicked:` 各自把事件快照传给 `activateRowAtIndex:modifiers:`，不在入口分别判断。

## VF 资源、条件替换与面板（2026-10-25）

| 符号 | 当前职责 |
| --- | --- |
| `GAFontResource` / `GAFontInstance` | 纯 CoreText 按默认坐标归并资源，保存实例菜单与轴；多资源 TTC 才显示选择 sheet |
| `GANormalizedFont` | 共同非默认坐标→默认坐标后 `CFEqual(CTFont)`，不经过 CGFont |
| `GAVariationViewController` / `GAVariationSlider` | 「可變」面板；系统 margins 与控件 intrinsic size 布局，数字框固定 66pt；方向键 ±1，Shift+方向键 ±10；滑杆连续更新 |
| `GAFeatureVariations`（private） | 每资源解析一次条件、替代 Feature 偏移、fvar/avar；以盒差集避开优先记录已覆盖区域，找出每个可达分支的代表坐标 |
| `GADiscoveryFonts`（private） | 资源级扫描字体集合：默认坐标优先，再加其余可达条件分支；扫描字体不反向引用集合，避免循环持有 |
| `GAFontDocument.rawScanContent:` | 扫描各分支并合并 GID、来源与覆盖范围；只有默认坐标的基础结果标记 base。条件替换作为列表选项，不自动替换单字画布的选定 GID |
| `directAlternatesForSeed:`（private） | 合并默认 Feature 与所有条件替代 Feature 的 single/alternate lookup；显式 GID 分析也能列出条件替换 |
| `documentWithDescriptor:` / `rebindResult:content:` / `rebindVariant:content:` | 新坐标共享已解析表及 inventory；沿用 literal GID/来源/范围，只更新字体与必要的位置 |
| `GATextScanModel.updateFontDocument:` | 资源级 content cache 与扫描队列保持不变，直接重绑当前组；切轴不重新枚举 context 或按分支重扫 |
| `GASidebarViewController.updateCoordinateGroups:` | 行成员、顺序、文字元数据不变时，只重绑行模型并配置可见 cell，不 reloadData、不重新选择、不滚动。成员变动或正常激活 pending 时交回原流式更新 |
| `GAAllGlyphsView.setDocument:` | 每个窗口只建立一次资源 inventory；后续只替换 fontBox 并使度量缓存失效。已删除换字体重建/回顶路径 |
| `popoverShouldDetach:` | 仅返回 YES，使用 NSPopover 自带的同外观 detached window 与同一内容控制器；不提供自订窗口；按钮可唤回已拖出的窗口，主窗口关闭时关闭 Popover |

- 「可變」按钮为 secondaryLabelColor，恢复最初的 borderless 原生按钮；不设置 bezelStyle，不添加方形容器或宽高约束。用户已放弃强制调整该处原生外观的宽度。
- Popover 默认 320pt 宽，超过五轴滚动。菜单使用 CTFontCopyName 的非本地化 style name，不使用 full name 或 CTFontCopyLocalizedName，避免系统自动翻译部分样式造成中英混杂。轴控件按 intrinsic size 与系统间距排列，滚动文档使用 layoutMarginsGuide 给控件外缘留白；不将 slider 高度硬设为 20pt，不强行贴齐裁切边缘。数字框固定 66pt，方向键 ±1，Shift+方向键 ±10，并限制在轴的 min/max 范围内。
- 附着中的 NSPopover 没有原生用户拖边缩放，本次按用户要求不添加自订拖曳手柄。contentSize 可由程序设置；detach 后保持系统原生外观，不为拉宽另建 NSPanel，也不修改系统窗口 styleMask。内容控制器 title 为空。附着时按系统 titled window 度量预留标题栏空间，菜单上方留白比上一版减少 18pt（原生 detach 后也保留这项间距调整）；popoverDidShow: 记录原始窗口和内容高度，popoverDidDetach: 保持原窗口总高度并消耗预留空间。
- 调轴时列表 GID 与顺序不变。选取自然保留，已删除切轴专用 pending selection/跳回流程；输入变化、正常激活与新扫描结果仍走原列表策略。
- 单字画布始终绘制选定 GID；例如 k 不会因跨条件变为 k.jump，选择 k.jump 后低字重仍画 k.jump 的轮廓。多字布局仍由当前坐标的 CoreText/TextKit 处理。
- 发现阶段使用默认坐标与条件分支的结果并集；代表点解析当前支持 Condition Format 1、avar 1。未支持的新条件/坐标映射仍可枚举已有 single/alternate 规则，但不能保证发现其上下文条件分支。
- `opsz` 显式固定，不跟随显示字号。分支代表点判定使用 descriptor 原始请求值，避免 CTFontCopyVariation 截短小数。
- 旧 multi scan 捕获原文档/模型，完成时核对后再提交；模型安装后重新投递最新输入，防止旧任务污染新坐标。

## 13. 更新规则

- 代码符号、行为、边界变化 → 改本文件对应表/段。
- 产品可见行为、测量、限制 → 写 `PRODUCT-LOG.md`。
- 协作方式、授权、踩坑 → 写 `COLLABORATION-NOTES.md`。
- 两份交接文档不再分版本；在文件内加日期/段落即可。
- 继任者可以直接修改文档，不需要先汇报；**改代码必须先弹窗确认**。
- 旧架构、旧符号、旧版本对比不要留在正文；如果确实需要历史，放在明确的“已废弃”小节并标注，不要和当前事实混在一起。



## GSUB/AAT 自写架构（2026-10-25，当前有效）

| 模块 | 职责与边界 |
| --- | --- |
| `GABinary` | 共享不可变字节、有界相对偏移、Coverage、ClassDef；不处理 UI 或字体 API |
| `GACmap` | Unicode cmap 0/2/4/6/8/10/12/13、UVS 14、symbol 与 MacRoman fallback；不回退到其他字体 |
| `GAGlyphBuffer` | 字面 GID、UTF-16 来源范围、稳定 token 身份、连字组件、变化记录、执行/输出预算；GDEF 过滤 |
| `GAOpenType` | GSUB/GPOS 的脚本、语言、feature、lookup、上下文模式与 FeatureVariations 程序；alternate 反向 family 索引只建一次 |
| `GARelatedSubstitutions` | 按查询 GID 遍历 feature 可达的 GSUB 动作，映射嵌套动作的目标位置；不要求输入上下文，合并全部 FeatureVariations 分支 |
| `GASubstitution` | GSUB 1–8；嵌套动作按每次替换后的输入位置执行，处理一对多、零输出、过滤、反向链与递归保护 |
| `GAAAT` | Apple lookup 0/2/4/6/8/10；morx/mort 0/1/2/4/5、16 种重排、状态/标记/栈/插入、方向、段尾动作和 chain selectors |
| `GAPositioning` | GPOS 1–9：单字/成对/连写/mark 附着及上下文定位；定位路径没有替换操作 |
| `GAVariation` | fvar/avar v1 正规化、ItemVariationStore、VariationIndex；GPOS 按实际坐标选择条件，GSUB 发现保持所有条件的并集 |
| `GAKerning` | kern 0/2/3 与 kerx 0/2 的成对/类别定位；只在 GPOS 未接管 kern 时使用 |
| `GATextPreparation` | grapheme 范围、NFC/NFD、UVS、脚本分段、系统 ICU bidi 与 Arabic joining forms；保留可编码的兼容字/UVS 基字 |
| `GAGlyphSelection` | 明确选择的 GID、原文范围快照和不可变查询身份；键包含文字、相对范围和完整 GID 序列，hash 纳入文字内容 |
| `GADisplayGroups` | 独立于窗口的列表数据构建；保留跨选择范围的新连字与选择字形本身的上下文结果，只对同来源/同 GID 的重复结果去重 |
| `GASubstitutionEngine.mm` | Objective-C 接口、CoreText 表字节/原生 advance 适配、资源共享、发现策略、来源合并和 NSCache；没有 CTLine/CTRun 扫描 |

每个字体资源共享不可变表程序及 family 索引；每次执行独立持有 buffer、状态、预算。切轴只绑定新的 CTFont/原生度量与定位，沿用条件并集缓存、GID、列表顺序和选择。文字/字面查询缓存为 NSCache（2048 项/32 MiB 软限制）；按 GID 的静态候选目录另用 NSCache（2048 项/16 MiB 软限制）。解析/执行失败通过线程安全 `diagnostics` 暴露，损坏的可选定位程序回退到原生 advance，不在后台线程抛出未处理异常。

文字查询仍是不同单字与每段一个多字任务。GSUB 在实际匹配时记录前文/输入/后文范围；AAT 使用状态转换、标记、栈和段尾动作记录相依岛，再只枚举岛内的 grapheme 窗口。相依范围可能覆盖整段，没有人为的上下文长度截断。feature/selector 分别枚举，不穷举所有可选设置的笛卡尔积。

每个输出携带原文 UTF-16 范围；被上下文修改的字形保留自己的来源，前后文只扩大查询窗口。候选身份为 GID 序列 + 是否组合 + 组合来源范围。GID 种子直接进入同一 buffer，完全不需要 identity cmap 或临时改写字体。段落查询也接收当前明确选择的 GID：先以字面 GID 替换对应输入区间，再与邻字一起执行规则。一个种子可含多个 GID 或覆盖多个原文字符；重叠来源合为原子替换，保留未被连字消耗的前缀/后缀。查询窗口会覆盖完整种子，不切断选择范围。单字/备用字形 family 支持未编码兄弟选项，但不一般性逆执行 GSUB。零输出保留 `∅` 行。

`GASeedDisplay`、完整多 GID 激活与点击映射沿用上一分支。CoreText/NSGlyphInfo 和 TextKit 继续负责显示；代码没有以 CoreText shaping 补做替换发现，也没有 HarfBuzz 或第三方字体执行器。

### 明确的能力边界

这是 Glyph Atlas 的替换表执行器，并非通用文字排版引擎。它没有实现 HarfBuzz 的全部专用 script shaper（例如 OpenType Indic 的音节分析、重排和分阶段掩码）；不能把 GSUB lookup 类型齐全说成所有文字系统与 HarfBuzz 等价。AAT 字体自己编码在 morx/mort 中的重排则会执行。

字面定位是未作像素 hinting 的设计单位布局；pixel Device deltas 不生效，VariationIndex 生效，Anchor format 2 使用表内设计坐标。尚未支持 kern 状态表 1、kerx 1/4/6、旧 AAT tuple kerning、avar v2。遇到这些定位程序会记录诊断并保留原生 advances，不退回 CoreText 扫描。多字视图的最终正常排版仍由原生 TextKit 完成。

旧 `GAOTProgram`、HarfBuzz callback、identity-cmap seed、CoreText feature-font 扫描及 `Sources/GASubstitutionEngine.m` 都属于上一版；当前接口实现为 `.mm`，对应 private core 位于 `Sources/FontLayout/`。

规范来源：[OpenType common formats](https://learn.microsoft.com/en-us/typography/opentype/spec/chapter2)、[GSUB](https://learn.microsoft.com/en-us/typography/opentype/spec/gsub)、[GPOS](https://learn.microsoft.com/en-us/typography/opentype/spec/gpos)、[Apple morx](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6morx.html)、[Apple mort](https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6mort.html)。


### 单字的上下文候选与来源（2026-10-25）

GSUB 查询增加与当前上下文无关的候选目录：从原始输入 GID 出发，只沿 feature 关联的 lookup/嵌套动作读取输出，保留动作针对的输入位置。输入 LucidaSubmono 的 `W` 即可列出 `W.w0`、`W.w1`（`calt`），不需要输入 `i`；不会把 `i.t1` 或整对 `W.w1+i.t1` 放到 W 的单字行。没有 feature 路径引用的孤立 lookup 不作为候选。目录包含所有 GSUB FeatureVariations 分支，切轴不重扫。

静态目录列出查询字形自身的直接/上下文替换，不预列需要其他组件的连字。GSUB type 4 无论直接引用、经 extension 或被上下文 lookup 调用，都必须由执行器匹配完整实际输入才产生候选；字面 GID 种子遵循同一规则。比如 f 或 i 单独不列 fi，输入 fi 才列 fi；W 则仍可独立列出 W.w0/W.w1。真实跨字组合保留完整来源范围。目录读取直接替换边，不是任意 feature 组合或上下文程序的通用符号执行器；嵌套动作中此前的直接一对多/删除，在输入可唯一确定时更新 SequenceIndex 的原始归属。复杂多候选/多阶段长度变化仍由实际上下文执行处理。morx/mort 继续使用其状态机执行路径，尚没有无上下文的全状态静态目录。

`actual` 是应用的备援标记，不是 GSUB feature tag。执行 Trace/静态目录有 `liga`、`calt` 等来源时直接保留，默认输出与基础候选也不再清掉来源；已知来源会替换 `actual`。所有来源均原文显示，`actual` 也不翻译。

侧栏的表格 document view 使用原生 frame/autoresizing 布局；reload 后显式失效所有行高并 tile，滚动范围由 NSClipView 的 constrainBoundsRect: 计算。该修复已编译，实际长列表滚动由用户做 GUI 验收；本轮没有启动窗口。


### 目录与测试构建清理（2026-10-25）

直接 single/alternate 与反向 alternate 兄弟候选统一进入 `relatedSubstitutions`；旧 `family` 接口已删除。每个候选带 directFamily 分类，只让直接根 lookup/兄弟选项参与默认 shaping 后的直接族查询；上下文输出仍绑定原输入的位置。反查只使用已解析的 alternateInputs 索引，不作一般 GSUB 逆执行。文字中的多 GID 种子与直接 GID 查询都保留未被替换的组件。

任务队列只为实际出现的查询长度建立有序分组，保留旧批次和正在执行对象。未使用的 hasFeatureVariations 布尔接口已删除，切轴行为继续由共享并集决定。

CLI 的 raw shape / feature specifications 只在测试模式编译，release 不包含这些 Objective-C 方法。解析与执行核心两模式共用。独立物件目录和编译配置签名共同避免测试物件进入 release；可用 `Tests/check-release.py` 检验最终两个架构的接口剔除。
