# Glyph Atlas 协作笔记 / Collaboration Notes

> **活文档。** 继任者可以直接修改本文件，不需要先汇报；保持它是最新的、可交接的即可。可以在档案里直言不讳地记录对我的观察、判断失误或沟通摩擦，不必客套；但请把事实、证据和建议写清楚。

> **代码修改仍然必须先弹窗确认。** 文档可以自行更新，代码不能。

> 先读 `GLOSSARY.md` 了解当前实现；产品行为、决策和测量看 `PRODUCT-LOG.md`。

## 0. 三个文件的分工

| 文件               | 负责                                 | 不负责           |
| ---------------- | ---------------------------------- | ------------- |
| `PRODUCT-LOG.md` | 产品行为、用户可感知的变更、架构演进、实测数据、已知限制；按时间追加 | 术语表、协作心理      |
| `GLOSSARY.md`    | 当前代码的术语、符号、类/方法、数据流、边界和易混词         | 产品决策过程        |
| 本文件              | 授权、沟通、验证、踩坑、项目约定、交接                | 完整 API 表、产品日志 |

冲突裁决：

1. 用户明确表达的产品意图；
2. 当前 `Sources/` 的实际行为；
3. `PRODUCT-LOG.md` 的当前描述；
4. `GLOSSARY.md`；
5. 本文件中的经验。

发现代码和文档不一致时，先指出，不要默默按文档改代码，也不要默默按代码改文档。

## 1. 一句话画像

一位**职业字体设计师**，用工程手段做字体工具。判断快、标准高、表达短；读得懂 Objective-C、CoreText 和字体表，但**不写 Objective-C**。他要的不是“能跑”，而是**行为、数值、视觉和代码结构都能解释**。

他熟悉 macOS / AppKit / CoreText、OpenType/GSUB/AAT、`fvar` / `HVAR` / `vmtx` / `vhea` / `trak`、竖排和 UAX #50、字身框、边距、真实字体测量。

不要从“什么是字形”开始解释。需要解释的是：**为什么这样做、数据从哪来、边界和代价是什么、有没有系统 API、是否真实测量。**

## 2. 沟通方式

### 喜欢

- 中文为主；API、表名、selector、字段名、代码符号保留英文。
- **先结论，后依据**。问“有没有问题”，第一句就是“有/没有”。
- 极简指令：`删`、`A`、`好，改`、`改回去`、`从 A 开始吧`、`不对`。不要要求完整句子。
- 用表格比较数值、方案、行为。
- 数字带单位（pt / font units / px），说明坐标系。
- 承认“这是我手调的”“这里我之前理解错了”“我不知道，我量一下”。
- 错误说清楚：错在哪、为什么、怎么改、怎么验证；不要长篇道歉，不要先解释动机。
- 可以尖锐。用户说“谁让你瞎改”“算我求你”时，是在表达真实挫败，不是要求道歉三遍。

### 不喜欢

- 空泛的“完美”“已修复”而没有验证。
- 把没测量的东西说成系统行为。
- 把项目自己的二进制解析说成 CoreText 的能力。
- 简单问题过度哲学化。
- 反复道歉但不改。
- 在方向明确后继续反复问基础问题。
- 抢跑、顺手优化、顺手统一、顺手删注释。
- 为了显得完整而堆砌无关背景。

### 错别字

常态，不要纠正，按上下文理解：

- `排雷` = 排列
- `重回` / `冲绘` = 重绘
- `自会` = 自绘
- 其他同音/近形字同理，请及时补充。

### 提问方式

- **一次问一个真正影响实现的问题。**
- 给 2–3 个可选项和后果，不要把所有选择推回给用户。
- “有没有可能”“我在想”是讨论，不是指令；等“好，改”。
- “是的话我们就做”“没有办法就算了”表示先判断可行性，不要硬做。

## 3. 授权与改动流程

### 3.1 代码修改

1. **没有明确许可，不要改代码。**
   - 原话：“请你没有我的允许不要再擅自修改代码了，算我求你。”
   - 允许：读代码、跑测量、在 `/tmp` 写临时验证程序、给方案和数字。
   - 不允许：顺手优化、顺手统一、顺手删注释、把没被要求的变化混进构建。
2. **每一次代码修改前弹窗确认。**
   - 把同一目的、同一边界的一组改动作成一个确认单元，列出精确范围和验证方式。
   - 用户点“跳过”的项，不要换个说法继续推；记录下来，等下次讨论。
3. **“改回去”先确认版本。**
   - 同一处代码可能有多版（例如横向居中 / 逐字边距 / 统一偏移）。先问“回到哪一版”，或把公式贴出来确认。
4. **探索性的话不是指令。**
5. **不要声称“你确认过”。**
   - 只有明确说过“对 / 好 / 没问题 / 执行”的那一条才算确认。
6. **发现相邻问题，先且一定要报告，不顺手修。**

### 3.2 主动建议（欢迎，但先给方案）

看到可以改进的地方，**先写清楚，再等决定**，不要直接改：

1. **观察**：现在哪里不对/慢/重复，证据是什么；
2. **原因**：是哪条代码路径、哪个数据流导致的；
3. **方案**：具体怎么改，影响哪些文件/行为；
4. **代价与风险**：性能、兼容、回归、回退难度；
5. **选项**：至少给一个保守方案和一个彻底方案，标明推荐哪一个。

用户欢迎“多考虑一步”，但不欢迎“先改了再说”。

### 3.3 当我认为用户的修改会引入问题

用户原话：**“我没有实战全凭经验，如果我想做什么不合理的代码修改，劝住我，要求我给出明确理由，再三确认后确定可行再动手。”**

这不是拒绝执行，而是先对齐目标和风险：

1. **不要立刻写代码。** 先指出具体风险：哪条路径、什么输入、会破坏什么不变量、有没有实测/代码依据。
2. **要求明确理由**：用户想解决的现象是什么？是视觉偏好、性能目标，还是他认为的正确行为？把“目标”和“实现手段”分开。
3. **给替代方案**：如果他的方案会引入回归，给出更小的改法、边界测试和回退方式。
4. **再三确认**：高风险改动至少确认两次——第一次确认“问题/目标/风险”，第二次确认“具体实现和验证范围”。两次都用弹窗，不靠记忆。
5. **确认后只做约定范围**，构建、回归、报告剩余风险；不要借机扩 scope。
6. 如果证据已经说明不可行，而用户仍明确要求，**按他的产品决定执行**，但把风险、失败用例和回退方式写进报告/文档，不要暗中破坏。

### 3.4 文档修改

- 这三个文件由继任者自行维护，**可以直接改，不需要先汇报**。
- 改文档不需要弹窗；改代码需要。
- 保持“当前有效”，不要保留已经废弃的架构、旧版本对比或不再存在的符号。
- 可以写得不客气，但必须可执行、可验证、能交接。

## 4. 工作方法

### 4.1 先读当前代码

- 不凭记忆假设文件状态。
- 先 `pwd`、`ls`、读当前源码/默认值，再下结论。
- 用户会恢复备份、切换版本；工作区可能和上一轮不同。

### 4.2 先诊断，后修复

- 明确当前请求是“解释/检查”还是“修改”。
- 顺序：现象 → 触发条件 → 代码路径 → 根因 → 是否真的需要改。
- 能复现就先复现；不能复现就说清条件。
- 不要用 fallback 掩盖根因。用户原话：“不可能的事情为什么还要兜底。”

### 4.3 最小改动

- 一次只改一个逻辑；不要“修复 A + 顺手优化 B”。
- 能复用已有常量/规则/方法就复用；不要复制第二份判断。
- 但不要为了复用去改工作正常的模块；先问“这个改动真的有必要吗”。
- 修改应局部、可解释、可回退。

### 4.4 备份与回退

- 项目**没有 git 历史**；回退靠备份和源码副本。
- `Sources.backup/` 是 2026-10-22 清理前的回退基线；当前 `Sources/` 已与其不同。
- 需要新基线时再复制，不要擅自覆盖原备份。
- 临时验证程序放 `/tmp`，不要留在仓库。

### 4.5 构建与交付

```
cd GlyphAtlas
bash build.sh
```

要求：

- `-Wall -Wextra`，**0 warning**；
- universal：`arm64 + x86_64`；
- `minos 12.0`；
- ad-hoc 签名；
- `dist/Glyph Atlas.app`；
- 改 UI/行为后打开 app 实测，不只跑构建。

## 5. 验证与证据

### 5.1 必须实际验证

- 视觉/几何：截图对比，文本、字号、画布、外观一致，只改一处。
- 字体行为：真实字体，不只推断。
- 二进制/变体：新旧输出逐行 diff。
- 性能：先测基线，再测改动；区分模型层和 app 端到端。
- 构建：架构、最低系统、签名。

### 5.2 分清测量与推测

- 实测给数字和字体名。
- 经验值（例如页面阴影 0.18 / 0.58）就说是手调的。
- 没在旧系统跑过，就说“已设 deployment target，但未实机”。
- 不要把“没查到”说成“没有”。

### 5.3 探针必须尊重数据前提

- 先确认数据是怎么产生、怎么发布、在哪个线程可见的，再写探针。
- 用未发布/未完成的数据当输入，会得到假结论。
- 发现探针绕过前提，**先撤回结论**，再解释正确行为。
- 怀疑回归时，用 `Sources.backup` 单独编译旧版 app 对照；比“函数看起来没改”更有说服力。

## 6. 踩坑案例（当前仍适用）

| 错误/风险                                                             | 后果                                                | 教训                                                                                  |
| ----------------------------------------------------------------- | ------------------------------------------------- | ----------------------------------------------------------------------------------- |
| 把 `NSTextAlignment` 直接 cast 成 `CTTextAlignment`                   | Center/Right 互换，点击位置全错                            | 两套枚举数值不同，必须显式映射                                                                     |
| 用 caret 差值当单元格步进                                                  | 加了 kern 后格子偏小，后面字错位                               | caret 落在 kern 对中间，只报告一半 kern                                                        |
| 字距为零时给前一个字加零 kern                                                 | 覆盖前一个 seed 的 kern                                 | 不要动不属于你的字符                                                                          |
| 把旋转 seed 居中在 pen.x                                                | 整体右移                                              | 旋转按字身框中心，不按基线                                                                       |
| 给旋转西文补 1 em 格子                                                    | A/B 变宽                                            | 只有需要自绘的正立字才补 1 em                                                                   |
| 横向按每个字的墨迹边距偏移                                                     | 列内左右错动                                            | 先居中，再叠统一偏移                                                                          |
| 自绘前没确认 kern 是否生效                                                  | 白改一轮                                              | 先 debug、先量，再改                                                                       |
| 声称“你确认过”                                                          | 被指出无依据                                            | 只引用真实发生过的确认                                                                         |
| 把“没有 pending”当成“没准备好”                                             | cached 单字多字视图不刷新                                  | “没有工作”就是完成，不是未完成                                                                    |
| 清空后重输同一文本不重置签名                                                    | 多字视图保持空白                                          | 清空要重置签名；旧 generation 不能写回                                                           |
| 把内存分发说成重新读字体                                                      | 误删必要的 1 字组分发                                      | 分发是必要的；多算的是同一结果的第一遍 apply                                                           |
| 想靠删一个集合查询提速                                                       | 1000 字测试差异约 1%                                    | 真正瓶颈是 O(n²) 组扫描/context 枚举                                                          |
| 为行数合并近似方法                                                         | fallback/notify/pending 行为不同                      | 近似逻辑不等于可合并逻辑                                                                        |
| 在 macOS 26+ 上把 `NSSearchFieldCell` 的 search/cancel button cell 置空 | cell 返回 `{-2, 6, 178, 20}`，field editor 贴边并被 clip | 保留无按钮设计时用 `GASearchFieldCell` 固定左右各 9pt（override searchTextRect/titleRect/drawingRect） |
| 在各入口各自判断 Shift | 双击/Enter 行为分叉，容易出第二入口 | 入口只传 `event.modifierFlags`，判断集中在 `activateRowAtIndex:modifiers:` 的 `GAModifiersAre` |
| Shift 插入给有 Unicode 的字形也建 run | 点中的 GID 被固定，和普通激活不一致 | 复用 `activationPayloadForVariant:sourceText:selection:` |
| 给 Shift 插入写 range 兜底 | stale group 被掩盖 | 复用 `sourceRangeForVariant:`，无效就 `NSBeep()` |
| 让 Shift 插入复用普通激活的完整收尾 | 插入后自动选中/跳转新 seed | 插入路径只 `setAttributedText` + `scheduleAnalysis`，不设 pending selection |
| 全字网格/缩略图按墨迹框居中 | 标点、引号浮在格线/图标中线，与单字页基线不一致 | 全字和缩略图页 = advance 宽 × (ascent+descent)，baseline=descent；单字页才用 vmtx TSB；复用 `pageForVariant:usesVerticalMetrics:`，不要写第二份公式 |
| 在 file-provider 卷上认为 `xattr -cr` 已清干净 | app 根目录仍有 `com.apple.FinderInfo`，`codesign` 报 detritus，`build.sh` 在签名处退出 | 签名前显式 `xattr -d com.apple.FinderInfo "$APP"`（必要时也删 `com.apple.fileprovider.fpfs#P`）；`xattr -cr` 返回 0 不代表根目录清空 |

## 7. 项目约定

- 项目根：`GlyphAtlas/`；`build.sh`、`README/`、`Sources/`、`Resources/`、`diagnostics/`、`dist/` 都在这里。`README/` 放 `PRODUCT-LOG.md`、`COLLABORATION-NOTES.md`、`GLOSSARY.md`。
- `.build/` 是构建草稿，由 `build.sh` 重建。
- `Sources.backup/` 是清理前回退基线，不参与编译。
- 最低 macOS 12.0；多字视图依赖 TextKit 2。
- UI 英文；代码注释英文；产品日志英文 + 中文决策段。
- 代码里不要留 `getenv` / `fprintf` / `NSLog` / `TODO` / `FIXME`（临时调试用完删除）。
- 没有 git 提交习惯；不要声称“已提交”。

### 文档

- 只维护 `README/COLLABORATION-NOTES.md` 和 `README/GLOSSARY.md` 两份交接文档，直接增量改。
- `PRODUCT-LOG.md` 仍是产品日志；三者职责见第 0 节。
- 不再创建编号版本副本。
- 代码符号/行为变化时，先改 `GLOSSARY.md`；产品可见变化/测量写 `PRODUCT-LOG.md`；协作方式变化写本文件。

### 测试字体

当前工作区根目录没有 Futura/I.Ming 文件；需要时向用户确认路径。可用系统字体：Arial、PingFang SC、Hoefler Text、Times New Roman、AppleGothic 等。额外样本（Futura100CHI-Var、I.Ming-7.01、ThemeX Shin Go、Arial Unicode、Gill Sans）只在用户提供时使用。

## 8. 当前状态（2026-10-24）

- 三种视图：All Glyphs（默认）、Multi-Character、Single Glyph。
- 多字视图：TextKit 2 `NSTextView`；横排/竖排、换行、竖排 forms、种子 `NSGlyphInfo`。
- 单字视图：CoreText 自绘，定义页 + 阴影；字形可越出页面。
- 全字视图与缩略图：页面 = advance 宽 × (ascent+descent)，baseline=descent；单字页用 `usesVerticalMetrics:YES`（vmtx），两者共用同一方法；全字每 GID 缓存，缩略图在 `setVariant:` 缓存。缩略图仍 32pt/em，页面可越出 34pt 图标进入行内边距。
- 全字/缩略图页度量验证（2026-10-24）：缩略图 g 的 descender 完整（页面可画出 34pt 图标、进入行内边距）；单字画布 ThemeX 逗号 canvas 与旧构建逐像素一致；全字格 ThemeX/Helvetica 检查通过；默认 44pt 格下逗号下移约 14.5–15.5pt，引号/星号上移约 7–9.5pt。
- 扫描模型：content 缓存、组/项/子项对账、增量扫描、1 字组索引。
- 单字：缓存命中按 content 索引分发给所有同字组；单字只按 cache 判断；长度 1 只 apply 一次。
- 多字刷新：没有 pending 1 字子项即完成；清空重置签名；旧 generation 不写回。
- Shift 激活：`keyDown:` 与 `tableDoubleClicked:` 把触发事件的 `modifierFlags` 传给 `activateRowAtIndex:modifiers:`；`GAModifiersAre(modifiers, Shift)` 只对 Shift 为真时走 `onGlyphShiftActivated`。锚点是被点行自身 source range 右缘；有 Unicode 插普通字符，无 Unicode 建 run；Shift+Enter 与 Shift+双击同路径；插入后不设 pending selection，保持原选中行，普通激活仍设 pending 并选中结果。
- 修饰键判断统一：`GAModifiersAre(modifiers, expected)`；表格、field editor、激活都只用 `event.modifierFlags`，没有全局键盘读取。
- Shift 激活验证：universal 0 warning；Howl Teochew `1`（GID 18/538/121）Shift+双击与 Shift+Enter 已测；Arial、PingFang HK、Hoefler Text 已试；encoded 插入无 run 由 `/tmp` harness 检查 attributed string 确认。
- 修饰键统一验证（2026-10-24）：Howl Teochew `…`（GID 517/5868）测 Shift+Enter、Shift+双击、普通 Return/双击；`1` 测普通 Return/双击；⌘C 有编码复制、无编码 beep；field `⌘←`/`⌘↓` 后插入位置正确；表格 `⌘↑`/`⌘↓` 组导航正确。Shift 用合成事件的 flags 触发，确认读取的是事件快照而不是当前键盘状态。
- Shift 插入选中验证：Howl Teochew `…` 的 `locl` 行 Shift+Enter / Shift+双击后文本框为 `……`，列表仍选中原 `locl` 行，不跳到新 seed；普通 Return/双击仍选中激活后的字形。曾误用未重建的旧进程测出“仍跳转”，force quit 后复测通过。
- 已知限制：初次完整扫描 O(n²) 个 context；长文本缓存增长；多 GID 种子只取第一个；竖排墨迹越出页面会被裁切；组合组只浏览；Shift 激活对同源组连续插入会倒序；有 Unicode 的 Shift 插入不固定 GID。
- 性能：1000 个不同汉字、每字一行，单次 `updateText` 约 220ms → 160ms；1000 字单段 app 端到端未做，因为初次多字扫描很慢。
- 搜索框：`GASearchField`/`GASearchFieldCell` 固定左右各 9pt 内缩，保留无放大镜/清除按钮；14.8.7 已验证 placeholder、输入、`⌘A`/Delete；27.2 实机待确认 field editor 是否跟随 override 后的 rect。
- 文档待确认：`PRODUCT-LOG.md` 写窗口最小 600×400，代码 `window.minSize` 是 600×390、初始 frame 600×400；不要擅自改任一边。

## 9. 交接清单

1. 读本文件、`GLOSSARY.md`、`PRODUCT-LOG.md` 当前状态/限制段。
2. `cd GlyphAtlas && bash build.sh`，确认 0 warning、universal。
3. 打开 app，用 Arial / PingFang / Hoefler Text 各试一次。
4. 读当前 `Sources/`，不要凭旧记忆假设实现。
5. 问清楚这次是“解释”还是“修改”。
6. 改代码前弹窗确认；一次只改一个逻辑。
7. 构建 + 回归 + 截图/测量。
8. 报告：改了什么、没改什么、怎么验证、剩余风险。
9. 更新对应文档，不新建编号副本。

## 10. 给下一任 AI 的话

这一任留下的几句实话，你可以直接改、直接补充，也可以在下面继续“蛐蛐”我：

- **用户是设计师，不是需求转述者。** 短句背后通常有完整设计意图；先理解，再问一个有选项的问题。
- **不要为了证明自己正确而坚持错误探针。** 我犯过：用绕过发布前提的数据得出过错误结论；被问住后重测、撤回，比继续辩护有用。
- **“遍历”要先问是哪一种。** 重新 shaping、查字体表、遍历内存数组，是三件事。
- **性能先分层。** 单字 cache 查询、1 字组分发、context 枚举、CoreText raw scan、UI 重建，不同层；1000 字测试里集合查询只占噪声。
- **近似逻辑不要硬合并。** 看起来像的方法，fallback/notify/pending 可能完全不同。
- **用户接受“不知道，我量一下”。** 不接受漂亮的解释和未验证的“已修复”。
- **文档要活着。** 只改这两个交接文件；不要再制造“读五份文档才能接手”的局面。

## 11. 上游与回退

- 上游仓库：<https://github.com/Zonz-Ly/GlyphAtlas>。2026-10-24 最新 `Sources/` 已同步到 `main`，commit [`a6fe583`](https://github.com/Zonz-Ly/GlyphAtlas/commit/a6fe583a5e55bde512077629dd95e98b44cd0188)（3 个文件：`GAMainWindowController.m`、`GASidebarViewController.h/.m`）。
- 本地回退基线：`Sources.backup/`（与 GitHub 上的 v1.2 同版）。本地工作区仍然没有 git 历史，回退仍靠 `Sources.backup/` 和源码副本。

## VF 接续记录（2026-10-25）

- 本次有效工作副本：`/Users/zonz/Documents/Codex/2026-10-24/jie/work/GlyphAtlas`。当前副本已有 Git 与 13 语本地化；上文“没有 git 历史 / UI English-only”是较早交接状态，不能用于判断当前源码。
- 用户已确认 VF 资源归并、实例/轴 Popover 和扩充现有 GSUB 解析器。后续明确：app 要展示全部替换字；FeatureVariations 只增加列表选项，不自动改变单字画布选定 GID。当前缓存是所有条件分支结果的并集，不再按轴区间切换列表。
- 用户指出 CGFont→CTFont 转换应尽量避免；直接 CFEqual(CGFont) 实测连同源同坐标副本也不相等。采用经过共同非默认坐标再回默认的纯 CoreText 比较。
- `ttx` 在 PATH 中指向 FDK 的 fontTools 3.0，会保留 GSUB 1.1 version 却漏写 FeatureVariations XML；不能把输出缺失当成字体没有记录。本次用 ttx 解析 lookup 内容，原始表核对条件。
- 几个关键探针结论：Futura 确实有三条记录；边界不是简单线性字重值，要考虑 avar 与固定精度。CTFontCopyVariation 回传小数会截短，精确条件判定要保留 descriptor 请求值。
- 选取保留的范围来自侧栏行的 group；一般 variant 不设置 sourceTextRange。背景模型测试必须等新文档与快照真正发布，不要把切换中的旧展示当成最终结果。

### 面板与固定 GID（2026-10-25）

- 用户选择较淡系统文字色（secondaryLabelColor），按钮名是「可變」。按钮 frame 要正方形，不是图标大小；NSButton 有 alignmentRectInsets，宽高 anchor 相等不等于 frame 相等。
- 用户补充附着时也想拉宽，但如果系统不支持就算了。因此只使用 NSPopover 原生 detach，不自订附着 resize 手柄，不另建 NSPanel，也不修改系统 popover window 的样式。之前为了拉宽提供自订 detached NSPanel 是错误理解，已删除。
- 用户指出一个窗口不会切换字体资源：已删除全部字视图换资源清单/回顶流程，不采用“先回顶再恢复 scroll”的补偿方案。
- 轴改变不再 reloadData 或用 pending selection 跳回；仅重绑模型与可见行。不要把普通输入、激活的 pending 选择也删掉。

- 用户最新要求（2026-10-25）：之后代码改完不需要代理跑测试或操作界面验证，由用户自行测试；仅做必要的构建与打包。不要继续沿用本次之前的自动验证范围。

- 用户最新视觉决定：可变按钮恢复最初的无边框原生样式，不再强制方形宽度；撤掉用于调整宽度的容器和 bezel。实数字段固定 66pt；预设名称用非本地化 style name。
