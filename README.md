# Glyph Atlas

A native macOS font and alternate-glyph inspector. Type text to see every alternate glyph, contextual substitution, and ligature the font provides for it, along with the typeset result and every glyph in the font.

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/62d2aca2-83aa-4f3f-ac30-e96c50b5aa45" />

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/da0c8b0d-6379-4665-b72f-7e3c42c1bddf" />

## Support

- macOS 12.0 or later
- .ttf .otf .ttc .otc .woff .woff2

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

## Usage

- Open a font, or drag one onto the app's window or Dock icon. Recently used fonts are supported.
- Type one or more characters in the sidebar to see all associated glyphs. Use `⌥⏎` to insert a line break.
- Double-click a glyph, or select it and press `Return`, to replace the default glyph and show that glyph's substitution.
- Use `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.
- All Glyphs is the default. Right-click to switch views, or press `⌘1` for Single Glyph, `⌘2` for Multi-Character, or `⌘3` for All Glyphs.
- In Multi-Character, click a glyph to view its alternates. Vertical writing is supported; right-click or press `⌘5` to switch writing direction.
- In All Glyphs, double-click a glyph to add it to the existing text. Clicking a glyph in the sidebar also makes it blink there.
- Use `⌘+`/`⌘-` to zoom the glyphs, and `⌥⌘+`/`⌥⌘-` to resize the margins in Multi-Character. Trackpad pinch also works.
- The page shadow shows the glyph's width and height, as well as the layout's line height and leading; press `⌘4` to hide it.
- Dark mode is supported. but be careful: clicking a solid glyph can blind you.

## Limitations

- Direct GSUB parsing covers single and alternate substitutions only; ligatures and contextual substitutions are discovered through CoreText shaping.
- Refreshing after entering long text can be a little slow, because of how alternates are discovered.
- Features or substitutions available only through private font tables, or not exposed by CoreText, cannot be enumerated.
- Glyph names depend on the font's glyph-name data (`post` table or CFF charset); when CoreText returns no usable name, the app shows `GID n`.
- Glyph width comes from the horizontal advance. When `vmtx`/`vhea` is present, glyph height comes from the vertical advance; otherwise it uses `ascent + descent`.
- Multi-Character layout and its metrics are provided by the system NSTextView; some effects are out of our control, yet it reflects the true rendering behavior of macOS.
- When the sidebar holds a lot of items, clicking gets twitchy and items sometimes fly around, witch Apple did. Use the arrow keys instead.
- Because of a system title-bar limitation, double-clicking the top of an All Glyphs window zooms the window; it can't be prevented, so don't be startled.

## Special thanks

- The entire app was personally built by DeepSeek Flash 1013 Max, with me nitpicking the whole time, at a total cost of 2,484,237,676 tokens.
- The English translation was also provided by DeepSeek Flash 1013.

---

# Glyph Atlas

一個原生 macOS 字體和替換字形查看器。輸入文字，查看字體為該文字提供的所有替換字形、上下文替換和連字，以及排版效果和所有字形。

## 支持

- macOS 12.0 或更高版本
- .ttf .otf .ttc .otc .woff .woff2

## 使用

- 打開字體，也可以把字體拖到 app 的窗口或圖標上，支持最近使用的文件。
- 在側邊欄中輸入單個或多個字符來查看所有關聯字形，可以用 `⌥⏎` 換行。
- 按兩下字形或選中後按 `⏎`，可以取代默認字形，顯示該字形的替換字。
- 使用方向鍵 `↑`／`↓` 選擇上下字形，使用 `⌘↑`／`⌘↓` 選擇上下默認字形，使用 `⌥↑`／`⌥↓` 選擇字形列表中的第一個和最後一個字形。
- 使用 `⌘C` 複製選中字形的所有編碼字符。
- 鼠標在 Unicode 上靜置時顯示該 Unicode 標準規定的字符名稱。
- 默認打开全部字形, 可以點右鍵切換或使用 `⌘1` 單字形、`⌘2` 多字符、`⌘3` 全部字。
- 在多字符中點一下字形就能查看替換字。支持豎排，點右鍵或使用 `⌘5` 切換。
- 在全部字中點兩下字形可以添加到已有文字中，在側邊欄中點一下字形還會在全部字中閃一閃。
- 用 `⌘+`／`⌘−` 來放大或縮小字形，用 `⌥⌘+`／`⌥⌘−` 來在多字符模式中放大或縮小邊距。也可以使用觸控板撐捏。
- 用陰影表示字形寬度高度和排版行高行距，用可用 `⌘4` 隱藏。
- 有做暗黑模式，但要小心點到實心字形會眼瞎瞎喔。

## 限制

- GSUB 直接解析只覆蓋 single/alternate；連字和上下文替換通過 CoreText 排版發現。
- 由於替換字發現原理限制，輸入長文本後刷新可能會有點卡。
- 只存在於字體私有表、或 CoreText 未暴露的特性無法枚舉。
- 字形名稱取決於字體的 glyph name 數據（post 表或 CFF charset）；CoreText 沒有可用名稱時顯示 GID。
- 字寬來自水平 advance。字高有 `vmtx`/`vhea` 時來自垂直 advance；無則使用 `ascent + descent`。
- 多字符排版及其度量由系統 NSTextView 提供，部分效果不可控但卻能反映真實的 macOS 渲染效果。
- 當側邊欄東西很多很多的時候，點起來會抽抽，有時還會飛，這是林檎幹的。用方向鍵代替操作可解。
- 由於系統標題欄限制，在全部字的窗口最上面點兩下會放大窗口，阻止不了，被嚇到不要意外。

## 特別鳴謝

- 整個 app 由 DeepSeek Flash 1013 Max 親自打造，並由本人全程指手畫腳，共計花費 24,8423,7676 偷啃。
