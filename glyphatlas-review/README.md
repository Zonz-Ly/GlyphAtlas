# GlyphAtlas 審查驗證案例

審查提交：`22174e5e4cd509db1613efb125a9dd4670e5f73c`。

這個資料夾提供獨立、可重跑的 C++ 函式摘錄測試，沒有修改 GlyphAtlas 儲存庫。它不是完整應用程式的建置或整合測試，也沒有經過 macOS、CoreText 字型載入器或 AppKit 介面。

`review_repros.cpp` 原樣保留了 `scriptTag`、`selectScript`、`adjust` 的函式邏輯，以及 GSUB type-4 解析分支。支援型別只保留該案例需要的欄位；二進位讀取與 Coverage 範圍驗證沿用原始實作。標記定位順序案例是原始定位公式與呼叫順序的數值模型，並非完整 GPOS 子表測試。

測試中的 assertion 用來確認目前程式的行為，因此執行成功表示「已重現問題」，不表示上游已修正。合成 GSUB 子表限制在小型受控案例，沒有產生完整字型檔。

## 執行

在提供 Clang 與 C++17 標準函式庫的環境中執行：

```sh
clang++ -std=c++17 -O1 -g -Wall -Wextra \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  review_repros.cpp -o review_repros
./review_repros
```

本次在 Linux 上以 Clang、AddressSanitizer 與 UndefinedBehaviorSanitizer 執行。輸出保存在 `repro_output.txt`。壓縮包沒有包含 Linux 執行檔。

## 驗證內容

腳本選擇：`GATextPreparation.mm` 的 `scriptTag` 把 `Deva`、`Beng`、`Mymr` 轉為舊式標籤；`GAOpenType.cpp:483–489` 的 `selectScript` 在只有 `dev2`、`bng2`、`mym2` 的 ScriptList 中無法找到對應腳本。測試也檢查直接給出字型支援的標籤時可成功選取，以區分標籤轉換與字型內容問題。

Kerning 覆寫：`GAPositioning.cpp:407–423` 的 `adjust` 在 override 模式下把整個 advance 設為 kerning 值。名義 advance 600、override kerning -50，實際得到 -50；應保留名義寬度並得到 550。先累加 -20 再以 -50 覆寫 kerning 的案例也應得到 550。

定位順序：`GASubstitutionEngine.mm:1122–1144` 先執行 GPOS，之後才套用 legacy kern。對 base、mark、next-base 的數值模型，GPOS 先把 mark 放在 x=300，隨後 legacy kern 把第一個 base 的 advance 由 600 改為 550，卻沒有重新解析 attachment，導致 mark 最終位於 x=250。完整字型整合案例仍待在 macOS 驗證。

解析展開：`GAOpenType.cpp:335–361` 將每個 LigatureSet 與 Ligature 引用展開成規則物件。使用重複引用的受控子表，424 位元組產生 10,000 個規則，1,224 位元組產生 90,000 個規則。這證明的是解析階段的工作量放大，沒有驗證整個應用程式的記憶體消耗、崩潰，或此類完整字型是否會通過 CoreText 載入。

## 修正方向

腳本查找應把 Unicode 腳本映射為該字型可用的 OpenType 標籤候選，保留新舊標籤相容性。盤點功能可依用途列舉支援的候選；這個修正本身不等於完成 Indic shaping。

Kerning 應在獨立的 delta 累積空間處理 additive、override、reset，再作用到名義 metrics。GPOS 與 legacy kern 的執行順序需要一併調整：名義 metrics → 必要的 legacy kern → GPOS → attachment resolution。不能只把 legacy kern 呼叫移到現有 GPOS 呼叫之前，因為 `Positioning::run` 會重新設定名義 metrics。

解析器需要全程共用的工作量預算，限制規則數、predicate 數、倒排索引項目數與展開資料總量，並在配置容器前檢查。執行階段的 Budget 不涵蓋載入時解析。共享可共用的子表資料可減少重複解析，但不能取代解析總量上限。

## 核對備註

固定提交的根目錄 Git tree 顯示 `build.sh` 的模式為 `100755`，因此不應把腳本缺少執行權限列為問題。可變座標切換時只重新計算位置的快取策略，也不能直接判為 Bug：目前替換盤點刻意列舉所有 GSUB variation branches。
