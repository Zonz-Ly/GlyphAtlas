# Glyph Atlas

A native macOS font and alternate-glyph inspector. Type text to see every alternate glyph, contextual substitution, and ligature the font provides for it, along with the typeset result and every glyph in the font.

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/62d2aca2-83aa-4f3f-ac30-e96c50b5aa45" />

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/da0c8b0d-6379-4665-b72f-7e3c42c1bddf" />

## Requirements

- macOS 12.0 or later

## Support

- .ttf .otf .ttc .otc .woff .woff2
- English, Chinese, Japanese, Korean, German, French, Spanish, Italian, Brazilian Portuguese, Russian, Vietnamese, Thai.

## Usage

- Open a font, or drag one onto the app's window or Dock icon. Recently opened items are supported.
- Use the menu bar to copy the font open in the current window to your user Fonts folder in one click.
- When you open a variable font, a variation panel appears beside the window controls. Drag it out to keep it open. Select a numeric value and use `↑`/`↓` or `⇧↑`/`⇧↓` to adjust it.
- Type one or more characters in the sidebar to see all associated glyphs. Use `⌥⏎` to insert a line break.
- Double-click a glyph, or select it and press `⏎`, to replace the default glyph and show its alternates. Hold `⇧` while doing this to add the glyph.
- Use `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.
- All Glyphs is the default. Right-click to switch views, or press `⌘1` for Single Glyph, `⌘2` for Multi-Character, or `⌘3` for All Glyphs.
- In Multi-Character, click a glyph to view its alternates. Contextual Alternates and Ligatures are on by default; toggle them with a right-click or `⌘5` and `⌘6`. Vertical writing is supported; right-click or press `⌘7` to switch.
- In All Glyphs, double-click a glyph to add it to the existing text. Clicking a glyph in the sidebar also makes it blink there.
- Use `⌘+`/`⌘−` to zoom the glyphs, and `⌥⌘+`/`⌥⌘−` to increase or decrease the margins in Multi-Character. Trackpad pinch also works.
- The shadow indicates the glyph's width and height, as well as the layout's line height and leading; press `⌘4` to hide it.
- Dark mode is supported, but be careful: clicking a solid glyph can dazzle you.

## Limitations

- Some font feature parsers, such as GSUB, are developed in-house. Their actual results are not guaranteed to match what CoreText exposes exactly, but so far testing has not shown any issues.
- Glyph names depend on the font's glyph-name data (`post` table or CFF charset); when CoreText returns no usable name, the app shows `GID`.
- Metrics come from CoreText: glyph width uses the horizontal advance. When `vmtx`/`vhea` is present, glyph height uses the vertical advance; otherwise it uses `ascent + descent`.
- Multi-Character layout and its metrics are provided by the system TextView; some effects are out of our control, for example, some required features such as `ccmp` cannot be disabled.
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

## 需要

- macOS 12.0 或更高版本

## 支持

- .ttf .otf .ttc .otc .woff .woff2
- 中文、日文、韓文、英文、德文、法文、西班牙文、義大利文、巴西葡萄牙文、俄文、越南文、泰文。

## 使用

- 打開字體，也可以把字體拖到 app 的窗口或圖標上，支持最近開啟的項目。
- 在菜單欄中可以把當前視窗的字體一鍵拷貝到用戶字體檔案夾。
- 打開可變字體時，在紅綠燈旁邊會有一個可變參數設置面板，還可以拖出來固定。選中數字後還可以按 `↑`／`↓` 或 `⇧↑`／`⇧↓` 調整數值。
- 在側邊欄中輸入單個或多個字符來查看所有關聯字形，可以用 `⌥⏎` 換行。
- 按兩下字形或選中後按 `⏎`，可以取代默認字形，並顯示該字形的替換字；如果同時按住 `⇧` 就是添加這個字了。
- 使用方向鍵 `↑`／`↓` 選擇上下字形，使用 `⌘↑`／`⌘↓` 選擇上下默認字形，使用 `⌥↑`／`⌥↓` 選擇字形列表中的第一個和最後一個字形。
- 使用 `⌘C` 複製選中字形的所有編碼字符。
- 鼠標在 Unicode 上靜置時顯示該 Unicode 標準規定的字符名稱。
- 默認打开全部字, 可以點右鍵切換或使用 `⌘1` 單字形、`⌘2` 多字符、`⌘3` 全部字。
- 在多字符中點一下字形就能查看替換字。默認開啟上下文替代和連字，點右鍵或使用 `⌘5`、`⌘6` 開關。支持豎排，點右鍵或使用 `⌘7` 切換。
- 在全部字中點兩下字形可以添加到已有文字中，在側邊欄中點一下字形還會在全部字中閃一閃。
- 用 `⌘+`／`⌘−` 來放大或縮小字形，用 `⌥⌘+`／`⌥⌘−` 來在多字符中放大或縮小邊距。也可以使用觸控板撐捏。
- 用陰影表示字形寬度高度和排版行高行距，用可用 `⌘4` 隱藏。
- 有做暗黑模式，但要小心點到實心字形會眼瞎瞎喔。

## 限制

- GSUB 等部分特性解析器自主研發，雖然實際結果不能保證和 CoreText 暴露的完全一致，但是目前測下來沒問題。
- 字形名稱取決於字體的 glyph name 數據（post 表或 CFF charset）；CoreText 沒有可用名稱時顯示 GID。
- 度量數據來自 CoreText：字寬來自水平 advance。字高有 `vmtx`/`vhea` 時來自垂直 advance；無則使用 `ascent + descent`。
- 多字符排版及其度量由系統 TextView 提供，部分效果不可控，比如 `ccmp` 等部分強制特性無法關閉。
- 由於系統標題欄限制，在全部字的窗口最上面點兩下會放大窗口，阻止不了，被嚇到不要意外。
