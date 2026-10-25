# Glyph Atlas

A native macOS font and alternate-glyph inspector. Type text to see every alternate glyph, contextual substitution, and ligature the font provides for it, along with the typeset result and every glyph in the font.

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/62d2aca2-83aa-4f3f-ac30-e96c50b5aa45" />

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/da0c8b0d-6379-4665-b72f-7e3c42c1bddf" />

## Requirements

- macOS 12.0 or later

## Support

- .ttf .otf .ttc .otc .woff .woff2
- English, Chinese, Japanese, Korean, German, French, Spanish, Italian, Brazilian Portuguese, Russian, Arabic.

## Usage

- Open a font, or drag one onto the app's window or Dock icon. Recently used fonts are supported.
- Type one or more characters in the sidebar to see all associated glyphs. Use `⌥⏎` to insert a line break.
- Double-click a glyph, or select it and press `⏎`, to replace the default glyph and show that glyph's substitution. Press and hold `⇧` together to add that glyph.
- Use `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.
- All Glyphs is the default. Right-click to switch views, or press `⌘1` for Single Glyph, `⌘2` for Multi-Character, or `⌘3` for All Glyphs.
- In Multi-Character, click a glyph to view its alternates. Use `⌘5` for contextual alternates and `⌘6` for ligatures; both start off. Use `⌘7` to switch writing direction.
- In All Glyphs, double-click a glyph to add it to the existing text. Clicking a glyph in the sidebar also makes it blink there.
- Use `⌘+`/`⌘-` to zoom the glyphs, and `⌥⌘+`/`⌥⌘-` to resize the margins in Multi-Character. Trackpad pinch also works.
- The page shadow shows the glyph's width and height, as well as the layout's line height and leading; press `⌘4` to hide it.
- Dark mode is supported. but be careful: clicking a solid glyph can blind you.

## Limitations

- This experimental copy discovers GSUB types 1–8 and AAT `morx`/`mort` substitutions with its own table interpreters. CoreText supplies font tables, native glyph metrics and drawing; system ICU supplies Unicode properties and bidi levels. TextKit still lays out the multi-character view. The interpreter is not a full script shaper; see [the implementation boundaries](README/GLOSSARY.md#明确的能力边界).
- Refreshing after entering long text can be a little slow, because of how alternates are discovered.
- Discovery covers default execution plus individual feature/selector values and all FeatureVariations records. Arbitrary combinations of optional settings and private shaping systems are not exhaustively enumerated.
- Glyph names depend on the font's glyph-name data (`post` table or CFF charset); when CoreText returns no usable name, the app shows `GID n`.
- Glyph width comes from the horizontal advance. When `vmtx`/`vhea` is present, glyph height comes from the vertical advance; otherwise it uses `ascent + descent`.
- Multi-Character layout and its metrics are provided by the system NSTextView; some effects are out of our control, yet it reflects the true rendering behavior of macOS.
- When the sidebar holds a lot of items, clicking gets twitchy and items sometimes fly around, witch Apple did. Use the arrow keys instead.
- Because of a system title-bar limitation, double-clicking the top of an All Glyphs window zooms the window; it can't be prevented, so don't be startled.

## Build

```
./build.sh
open "dist/Glyph Atlas.app"
```

The default build is universal (`arm64` + `x86_64`). To build only one architecture:

```
ARCHS=arm64 ./build.sh
ARCHS=x86_64 ./build.sh
```

---

# Glyph Atlas

一個原生 macOS 字體和替換字形查看器。輸入文字，查看字體為該文字提供的所有替換字形、上下文替換和連字，以及排版效果和所有字形。

The build assembles icons and the app in a temporary directory, removes metadata, signs and verifies the app, then writes the results to `dist`. Temporary files are removed automatically. `--zip` creates the archive without unpacking it for another signature check.

## 需要

- macOS 12.0 或更高版本

## 支持

- .ttf .otf .ttc .otc .woff .woff2
- 中文、日文、韓文、英文、德文、法文、西班牙文、義大利文、巴西葡萄牙文、俄文、阿拉伯文。

## 使用

- 打開字體，也可以把字體拖到 app 的窗口或圖標上，支持最近使用的文件。
- 在側邊欄中輸入單個或多個字符來查看所有關聯字形，可以用 `⌥⏎` 換行。
- 按兩下字形或選中後按 `⏎`，可以取代默認字形，並顯示該字形的替換字；如果同時按住 `⇧` 就是添加這個字了。
- 使用方向鍵 `↑`／`↓` 選擇上下字形，使用 `⌘↑`／`⌘↓` 選擇上下默認字形，使用 `⌥↑`／`⌥↓` 選擇字形列表中的第一個和最後一個字形。
- 使用 `⌘C` 複製選中字形的所有編碼字符。
- 鼠標在 Unicode 上靜置時顯示該 Unicode 標準規定的字符名稱。
- 默認打开全部字形, 可以點右鍵切換或使用 `⌘1` 單字形、`⌘2` 多字符、`⌘3` 全部字。
- 在多字符中點一下字形就能查看替換字。`⌘5` 使用上下文替換、`⌘6` 使用連字，兩者默認關閉；`⌘7` 切換豎排。
- 在全部字中點兩下字形可以添加到已有文字中，在側邊欄中點一下字形還會在全部字中閃一閃。
- 用 `⌘+`／`⌘−` 來放大或縮小字形，用 `⌥⌘+`／`⌥⌘−` 來在多字符模式中放大或縮小邊距。也可以使用觸控板撐捏。
- 用陰影表示字形寬度高度和排版行高行距，用可用 `⌘4` 隱藏。
- 有做暗黑模式，但要小心點到實心字形會眼瞎瞎喔。

## 限制

- 此實驗副本使用自寫的字體表執行器發現 GSUB 1–8 類及 AAT `morx`／`mort` 替換。CoreText 提供字體表、原生字形度量與繪製，系統 ICU 提供 Unicode 屬性及雙向層級；多字視圖仍由 TextKit 排版。執行器尚未涵蓋完整的專用文字整形流程，見[實作邊界](README/GLOSSARY.md#明确的能力边界)。
- 由於替換字發現原理限制，輸入長文本後刷新可能會有點卡。
- 發現範圍包括預設執行、各個特性／選擇器值，以及所有 FeatureVariations 記錄；不窮舉可選設定的任意組合或私有排版系統。
- 字形名稱取決於字體的 glyph name 數據（post 表或 CFF charset）；CoreText 沒有可用名稱時顯示 GID。
- 字寬來自水平 advance。字高有 `vmtx`/`vhea` 時來自垂直 advance；無則使用 `ascent + descent`。
- 多字符排版及其度量由系統 NSTextView 提供，部分效果不可控但卻能反映真實的 macOS 渲染效果。
- 當側邊欄東西很多很多的時候，點起來會抽抽，有時還會飛，這是林檎幹的。用方向鍵代替操作可解。
- 由於系統標題欄限制，在全部字的窗口最上面點兩下會放大窗口，阻止不了，被嚇到不要意外。

## 特別鳴謝

- 整個 app 由 DeepSeek Flash 1013 親自打造，並由本人全程指手畫腳，共計花費 24,8423,7676 偷啃。


## 實作與開發檢查

產品程式碼全部使用 Objective-C（Sources 內的 .h/.m），以系統 AppKit、CoreText 和 ICU 工作；沒有 C++、HarfBuzz 或其他外部字體執行器依賴。Sources 維持平鋪。Tests 保存命令行檢查及自製測試字體，不會打包進 App；scripts 只協助重用測試用的核心編譯物件。架構與限制見 README/GLOSSARY.md。
