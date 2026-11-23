# GlyphAtlas 程式碼審查

我按 `main` 的固定提交 `22174e5e4cd509db1613efb125a9dd4670e5f73c` 做了這輪審查，重點覆蓋字型表解析、替換與定位、查詢快取，以及部分介面到查詢引擎的呼叫鏈。找到三項正確性問題、一項解析工作量放大的問題，另有幾個值得精簡的地方。這次執行的是抽取原始函式的 C++ 最小測試；沒有在 macOS 上編譯、執行完整應用程式，因此下文會區分已驗證的函式行為與仍需整合測試的影響。

先說最值得優先處理的問題：解析器有讀取邊界檢查，但解析時的物件展開量仍缺少整體上限。具體位置是 `Sources/FontLayout/GAOpenType.cpp:335–361`，GSUB type 4 的處理會逐一展開 LigatureSet、Ligature 與輸入序列，每次都建立新的 `Pattern`。不同 offset 可以指向同一份資料，因此檔案大小不一定能限制解析後的資料量。現有執行階段的 `Budget` 並沒有涵蓋這段載入時的解析。[^opentype] [^buffer-header]

我用受控的重複引用子表做了測試：424 位元組產生 10,000 個規則，1,224 位元組產生 90,000 個規則，所有讀取仍在資料範圍內。這驗證了工作量放大，尚未驗證完整字型是否能通過 CoreText 載入，也沒有把它當成已重現的應用程式崩潰。修正上，建議增加共用的解析預算，在配置容器前限制規則數、predicate 數、索引項目數與展開資料總量，並把取消檢查延伸到解析階段。可以共用的子表應避免重複解析，但單靠共用仍不能取代總量限制。我會把這項健壯性工作排在前面。

接下來是可以直接修正的定位錯誤。`Sources/FontLayout/GAPositioning.cpp:407–423` 的 `adjust()`，在舊式 `kern` 子表設有 `override` 時，執行的是 `target = value`；當 `target` 指向 `xAdvance`，原本的字寬就一起被覆寫了。規範中的 override 是覆寫累積的 kerning 調整值，並不應丟掉名義 advance。[^positioning] [^kern-spec]

這個最小案例已重現：名義 advance 為 600，override kerning 為 −50，目前結果是 −50，預期應為 550。先套用一般 kerning −20，再以 −50 覆寫的案例，也得到相同錯誤。比較清楚的修法是把 kerning delta 獨立累積，讓 additive、override、reset 都只作用於 delta，最後再加回 advance 或 offset。如此也能避免 cross-stream reset 意外清掉其他定位步驟留下的位移。

同一條定位流程還有另一個獨立問題：legacy kern 的套用順序太晚。`Sources/FontLayout/GASubstitutionEngine.mm:1122–1144` 先完成 GPOS，再在 GPOS 沒有接管 kerning 時執行舊式 kern；但 GPOS 內部已經根據當時的 advance 算完 mark attachment。後續再改 advance，會讓標記位置與附著的基底不一致。OpenType 的建議順序也明確要求：沒有可用的 GPOS kern lookup 時，先套用舊式 kern，再處理其餘 GPOS feature。[^substitution-engine] [^positioning] [^recommendations]

以「基底、組合標記、下一個基底」為例，名義 advance 600，GPOS 先把標記放在基底的 x = 300。之後 kern 把第一個基底的 advance 減少 50，標記卻沒有重新計算，最終會落在 x = 250。我以現有公式與執行順序的數值模型重現了這個偏移；完整字型案例仍需在 macOS 驗證。修正時建議把流程拆清楚：名義 metrics → 必要的 legacy kern → GPOS → attachment resolution。不能只把 kern 呼叫搬到現有 `gpos.position()` 前面，因為 `Positioning::run()` 會重新設定名義 metrics，前面算好的 kern 又會被清掉。[^positioning]

第三項正確性問題是部分文字腳本的 OpenType 標籤沒有被選到。`Sources/FontLayout/GATextPreparation.mm` 的 `scriptTag()` 大致把 ICU 的腳本名稱轉成小寫；而 `GAOpenType.cpp:483–489` 的 `selectScript()` 只嘗試目前標籤、`DFLT`、`latn`。因此 `Deva` 會變成 `deva`，卻不會嘗試字型可能實際使用的 `dev2`；`Beng`／`bng2`、`Mymr`／`mym2` 也有同類問題。OpenType 的腳本標籤與 Unicode／ISO 腳本名稱並非一對一，規範也列出了這些新舊標籤。[^text-preparation] [^opentype] [^script-tags]

函式測試中，當 ScriptList 只有 `dev2`，以 `Deva` 經過目前轉換後確實選不到腳本；直接傳入 `dev2` 則可以。影響需要說得精確：部分單字形替換仍可能被靜態 catalogue 找到，但需要完整輸入序列的連字查找會漏掉，因為 catalogue 明確跳過 type 4，依賴實際 executor 發現組合；一般文字輸入又只從 `run.script` 開始查找。[^glyph-catalogue] [^substitution-engine]

建議把腳本對應改成「Unicode 腳本 → OpenType 標籤候選 → 與字型 ScriptList 配對」，保留新舊標籤相容性。盤點功能可以按用途列舉字型支援的候選，實際排版則選擇適用版本；不宜單純把所有 `deva` 硬換成 `dev2`。這會修正查找入口，但本身不等於完成所有 Indic shaping 規則。

介面方面，有一條同步重工作路徑值得改。`GAMainWindowController` 的全字形雙擊回呼直接進入 `appendAllGlyphEntry:`；遇到沒有 Unicode 映射的字形時，它在介面回呼中呼叫 `variantsForGlyphIDs:cancelled:nil`，只是為了尋找可以借用的來源字元。這個呼叫會一路進入 `discoverGlyphIDs`，列舉替換分支、腳本、語言與 feature plans，之後還會替候選計算位置與標籤。[^main-window] [^font-engine] [^substitution-engine]

這是可確認的主執行緒同步查詢路徑，實際卡頓時間尚未量測。冷快取、替換規則多的字型會比較值得測試。改善可以分兩步：先提供只尋找來源 Unicode 的輕量查詢，避免為此建立完整的 `GAGlyphVariant` 與 positions；仍然需要完整探索時，就交給現有背景佇列，帶取消訊號，完成後核對字型與請求世代，再執行插入並保留單次 undo 語義。專案已經有這類非同步請求的處理方式，例如字形 feature filter，沿用它比新增另一套機制更合適。[^main-window]

精簡方面，我認為最有價值的是減少重複解析。`Predicate::classified()` 每次都從 `View` 建立 `ClassDef`，而 format 2 的 contextual rules 會反覆對同一份 ClassDef 呼叫這條路徑；`ClassDef` 建構時又會驗證表內容。可以在子表層級按需解析一次，讓多個 predicate 共用已驗證的不可變資料。`PositioningTables` 已經展示了類似的共用思路，這個方向能減少重複工作，也讓「哪裡負責驗證」更集中。[^opentype] [^binary]

另一處適合收斂的是分析請求的狀態管理。`GAMainWindowController` 同時持有 `analysisQueue`、worker document、query model、pending text、pending selections、pending document 和 generation 等狀態。建議把這組責任抽成一個分析請求協調器，控制器只提交請求、接收完成的 snapshot；現有 `GATextQueryModel` 繼續負責查詢模型。這樣拆分的理由是狀態所有權會更清楚，無須再增加一整套泛用架構。[^main-window] [^query-model]

錯誤結果也值得整理。目前 `discoverText` 捕捉一般例外後回傳空陣列，而 `incomplete` 可以仍為 `NO`；上層模型便可能把這次結果視為已完成，記住 query identity。對字型檢查工具而言，「真的沒有候選」和「這段字型程式無法解析或執行」最好能區分。可以沿用 `GARawScanResult` 增加診斷原因，保留已取得的候選，讓介面顯示不完整原因；沒有必要另造很多層結果物件。[^substitution-engine] [^query-model]

至於測試，這個提交的根目錄與建置腳本中沒有看到回歸測試或 CI 入口，`build.sh` 主要負責編譯、組裝與打包。下一步最值得補的是純 C++ 解析／查找測試，以及少量 macOS 整合測試。前者先納入這次的腳本標籤、kern override、kern 與 mark 順序、重複 offset 展開，再增加截斷表與取消測試；後者則驗證快速切換字型、拖動可變軸、輸入後立即 undo、分析尚未完成時關閉視窗等跨佇列情境。[^repository] [^build]

目前的幾個設計可以保留：`View` 集中處理二進位邊界、共用不可變字型資源與座標實例分開、查詢模型只發布完成的投影，這些都有清楚用途。可變座標切換時只重算位置的快取策略，我沒有列為問題，因為替換盤點本來就刻意列舉所有 variation branches。[^binary] [^substitution-engine] [^query-model]

我會按「補最小回歸測試 → 限制解析展開 → 修正兩項 kerning 問題 → 補腳本標籤對應 → 移除雙擊路徑的同步重查詢 → 收斂狀態管理」的順序推進。這輪已把函式摘錄測試、執行輸出與修正注意事項整理成[驗證案例包](GlyphAtlas-review-reproductions.zip)；它不含字型或平台執行檔，也沒有改動儲存庫。

[^opentype]: [GAOpenType.cpp（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GAOpenType.cpp)
[^buffer-header]: [GAGlyphBuffer.h（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GAGlyphBuffer.h)
[^positioning]: [GAPositioning.cpp（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GAPositioning.cpp)
[^kern-spec]: [OpenType 規範：kern](https://learn.microsoft.com/en-us/typography/opentype/spec/kern)
[^substitution-engine]: [GASubstitutionEngine.mm（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GASubstitutionEngine.mm)
[^recommendations]: [OpenType 規範：Recommendations](https://learn.microsoft.com/en-us/typography/opentype/spec/recom)
[^text-preparation]: [GATextPreparation.mm（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GATextPreparation.mm)
[^script-tags]: [OpenType 規範：Script tags](https://learn.microsoft.com/en-us/typography/opentype/spec/scripttags)
[^glyph-catalogue]: [GAGlyphCatalogue.cpp（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GAGlyphCatalogue.cpp)
[^main-window]: [GAMainWindowController.m（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/App/GAMainWindowController.m)
[^font-engine]: [GAFontEngine.m（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/Font/GAFontEngine.m)
[^binary]: [GABinary.h（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/FontLayout/GABinary.h)
[^query-model]: [GATextQueryModel.m（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/Sources/Font/GATextQueryModel.m)
[^repository]: [GlyphAtlas 儲存庫（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/tree/22174e5e4cd509db1613efb125a9dd4670e5f73c)
[^build]: [build.sh（固定提交）](https://github.com/Zonz-Ly/GlyphAtlas/blob/22174e5e4cd509db1613efb125a9dd4670e5f73c/build.sh)
