# GlyphAtlas 第三輪 review：局部驗證與整合測試提案

審查提交：`f4acc1c92366b4210f2aaecdcd1cd2a2ad9368e1`。

## 實際驗證範圍

`review_checks.cpp` 已在 Linux 使用 clang++ 執行，普通版本及 AddressSanitizer／UndefinedBehaviorSanitizer 版本均通過，兩份輸出相同。這份程式包含從現有程式摘錄的 mark 父標記搜尋迴圈，以及連字候選位置、feature/value 列舉和 RTL pen 工作量的合成模型。它沒有連結完整儲存庫，也沒有讀取真實字型或執行 CoreText／AppKit。

`production_mark_regression.cpp` 是另附的正式原始碼整合測試提案，使用合成 GPOS bytes，呼叫公開的 `OpenType::position()`。此程式未在本次環境編譯、執行；不能將局部驗證的結果當成它已通過建置。預期現有提交會在兩個案例中回傳失敗，修正後才應通過。

本次沒有執行儲存庫內的完整測試套件，沒有修改遠端儲存庫。本檔案包不包含字型或執行檔。

## 重跑已執行的局部檢查

```sh
bash run-focused-checks.sh
SANITIZE=1 bash run-focused-checks.sh
```

檢查包含：沒有 lookup flags 時，不應跨過未被 mark2 coverage 收錄的相鄰 mark；使用 mark filtering 時，父標記搜尋必須略過被過濾的 mark。這兩項的預期依據是 OpenType GPOS type 6 對父標記的定義：依 LookupFlags 找到前一個 glyph，再檢查 mark2 coverage。

標準依據：https://learn.microsoft.com/en-us/typography/opentype/spec/gpos （Lookup type 6）。

連字部分比較 1,000 組有序位置集合，確認改用單向游標仍產生相同的略過位置。8,192 個連續 component 的測試，只計算 membership equality comparisons；33,558,528 與 8,192 的差別不是整個 App 的加速比，也沒有涵蓋連字刪除、frame 更新與 provenance。

featurePlans 部分比較 200 組合成規格，確認緊湊表示的訪問順序和展開陣列一致。256 個 feature、每個 32,768 個值的合成配置，包含 default plan 共 8,388,609 個 pair。此環境的元素儲存量為 67,108,872 bytes，vector capacity 為 134,217,728 bytes；緊湊規格本身是 2,048 bytes。這是配置模型，沒有生成或載入完整字型；capacity 也會隨標準函式庫實作而不同。

RTL 測試只驗證現有逐一向前累加 suffix 的工作量，並示範浮點加法順序可能改變結果，未宣稱 suffix cache 可在所有情況保留逐位相同的數值。

## 在儲存庫上執行新增的 mark 整合測試提案

```sh
SOURCE_ROOT=/path/to/GlyphAtlas bash run-production-mark-checks.sh
SOURCE_ROOT=/path/to/GlyphAtlas SANITIZE=1 bash run-production-mark-checks.sh
```

測試直接編譯正式 FontLayout C++ 檔案，不需要 CoreText。案例一輸入 `[base, markA, markB, markC]`，mark1 coverage 只有 C、mark2 coverage 只有 A、flags=0；C 應保持 yOffset=0。案例二讓 mark2 coverage 同時包含 A、B，但 mark filtering set 排除 B；C 應對齊 A，yOffset=500，而非 B 的 900。

對現有實作的預測是案例一得到 500、案例二得到 900；這是依程式追蹤及局部迴圈驗證所得的預測，不是本次整合程式的執行輸出。

## 測試範圍與後續

現有回歸程式已有實質 assertions，但 transcript 案例和取消案例不全都具有對應期望；輸出檔產生成功不能單獨保證所有結果正確。正式修正時，應將上述 cases 加入原有 suite，並讓意外結果導致非零退出。對系統字型的跨版本 transcript 比較，需要同時固定環境，或改用可控 fixture。
