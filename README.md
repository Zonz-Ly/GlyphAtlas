# Glyph Atlas

A native macOS font and alternate-glyph inspector. Type text to see every alternate glyph, contextual substitution, and ligature the font provides for it, along with the typeset result and every glyph in the font.

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/62d2aca2-83aa-4f3f-ac30-e96c50b5aa45" />

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/da0c8b0d-6379-4665-b72f-7e3c42c1bddf" />

## Requirements

- macOS 12.0 or later.

## Support

- .ttf .otf .ttc .otc .woff .woff2 .dfont
- English, Chinese, Japanese, Korean, German, French, Spanish, Italian, Brazilian Portuguese, Russian, Vietnamese, Thai.

## Build

```
./build.sh
```

The default build uses the current machine's architecture. Use a flag to select an architecture or create a ZIP:

```
./build.sh -a       # arm64
./build.sh -x       # x86_64
./build.sh -u       # Universal (arm64 + x86_64)
./build.sh -z       # Current architecture + ZIP
./build.sh -u -z    # Universal + ZIP
```

## Opening the app

- ZIPs created by the build script or downloaded from [Releases](https://github.com/Zonz-Ly/GlyphAtlas/releases) contain the app and `Clear Attributes.command`.
- If macOS blocks the app from opening, extract `Clear Attributes.command` into the same folder as the app and double-click it to run `xattr -rc` on the app. You can then open the app.
- If the app still won't open after using the script, open the built-in Terminal app, type `xattr -rc`, then **a space**, and drag the app into the window. Check that the app's file path has appeared, press Return, then open the app.

## Usage

- Open a font, or drag one onto the app's window or Dock icon. Recently opened items are supported. Hold `⌥` before choosing Open Font in the menu bar for more options.
- Use the menu bar to copy the font open in the current window to your user Fonts folder in one click. Hold `⌥` to copy it to the Fonts folder for all users.
- When you open a variable font, a variation panel appears beside the window controls. Drag it out to keep it open. Select a numeric value and use `↑`/`↓` or `⇧↑`/`⇧↓` to adjust it.
- Type one or more characters in the sidebar to see all associated glyphs. Use `⌥⏎` to insert a line break. You can also right-click and choose “Saved Text” to save the current text or quickly enter text you’ve saved before. Hold `⌥` in the menu bar to quickly delete saved text.
- Double-click a glyph, or select it and press `⏎`, to replace the default glyph and show its alternates. Hold `⇧` while doing this to add the glyph.
- Use `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.
- All Glyphs is the default. Right-click to switch views, or press `⌘1` for Single Glyph, `⌘2` for Multi-Character, or `⌘3` for All Glyphs.
- In Multi-Character, click a glyph to view its alternates. Right-click or press `⌘5` to switch between horizontal and vertical writing. Text alignment and Typography are here too. The View menu in the menu bar has more options.
- In All Glyphs, hover over a glyph to see its details or double-click to add it to the existing text. Clicking a glyph in the sidebar makes it blink in All Glyphs. Right-click to find Filter by Feature.
- Use `⌘+`/`⌘−` to zoom the glyphs, or pinch on the trackpad. In Multi-Character, use `⌥⌘+`/`⌥⌘−` or a horizontal pinch to increase or decrease the margins, and `⌃⌘+`/`⌃⌘−` or a vertical pinch to increase or decrease line spacing. Press `⌘0` to restore the default size.
- The shadow shows the bounding box, including the glyph's width and height and the layout's line height and leading; press `⌘4` to hide it.
- Dark mode is supported. Watch out when clicking a solid glyph, as it can dazzle you. You can change the glyph, bounding box shadow, and background colors under Colors in the menu bar. Choose Save Current Palette to keep your colors. Hold `⌥` to find Delete Palettes.
- Choose Use as Defaults in the menu bar to save the current view, colors, size, other preview settings, and window size. Font files you open later will use these settings. Hold `⌥` to choose Restore to Defaults instead.

## Limitations

- The sidebar and the All Glyphs filter use in-house GSUB and AAT parsers. They follow the font's own tables, so their results can differ from CoreText's processed results.
- Glyph names come from CoreText. When CoreText returns no usable name, the app shows `GID`.
- Glyph width comes from CoreText's horizontal advance.
- Glyph height comes from CoreText's vertical advance when `vmtx` is present. Otherwise it uses `sTypoAscender + sTypoDescender`. If those are unavailable, or in Multi-Character, it uses CoreText `ascent + descent`.
- The system TextView provides Multi-Character layout and metrics, reflecting how macOS actually typesets the text. The app filters missing glyphs out of the preview because TextView has no option to turn off font fallback.

---

# Glyph Atlas

一個原生 macOS 字體和替換字形查看器。輸入文字，查看字體為該文字提供的所有替換字形、上下文替換和連字，以及排版效果和所有字形。

## 需要

- macOS 12.0 或更高版本。

## 支持

- .ttf .otf .ttc .otc .woff .woff2 .dfont
- 中文、日文、韓文、英文、德文、法文、西班牙文、義大利文、巴西葡萄牙文、俄文、越南文、泰文。

## 開啟

- 構建生成或從 [Releases](https://github.com/Zonz-Ly/GlyphAtlas/releases) 下載的 zip 裡面有 app 和 `Clear Attributes.command`。
- 如果 app 被系統攔住打不開，把 `Clear Attributes.command` 解壓到同一檔案夾內，按兩下腳本就能幫 app 執行 `xattr -rc`，然後就可以打開了。
- 如果用了腳本還是打不開，就打開系統自帶的終端機 app，輸入 `xattr -rc`，**空格**，把 app 拖進來，確認終端機 app 中出現了 app 的文件路徑後，按回車，然後就可以打開了。

## 使用

- 打開字體，也可以把字體拖到 app 的窗口或圖標上，支持最近開啟的項目。在菜單欄點開啟字體前按住 `⌥` 還有更多選擇。
- 在菜單欄中可以把當前視窗的字體一鍵拷貝到用戶字體檔案夾。按住 `⌥` 可以改拷貝到所有用戶的字體檔案夾。
- 打開可變字體時，在紅綠燈旁邊會有一個可變參數設置面板，還可以拖出來固定。選中數字後還可以按 `↑`／`↓` 或 `⇧↑`／`⇧↓` 調整數值。
- 在側邊欄中輸入單個或多個字符來查看所有關聯字形，可以用 `⌥⏎` 換行，還可以點右鍵找到「常用文字」，記住目前文字或快速輸入之前記住的文字。也可以在菜單欄中按住 `⌥` 來快速刪除。
- 按兩下字形或選中後按 `⏎`，可以取代默認字形，並顯示該字形的替換字。如果同時按住 `⇧` 就是添加這個字了
- 使用方向鍵 `↑`／`↓` 選擇上下字形，使用 `⌘↑`／`⌘↓` 選擇上下默認字形，使用 `⌥↑`／`⌥↓` 選擇字形列表中的第一個和最後一個字形。
- 使用 `⌘C` 複製選中字形的所有編碼字符。
- 鼠標在 Unicode 上靜置時顯示該 Unicode 標準規定的字符名稱。
- 默認打開全部字，可以點右鍵切換或使用 `⌘1` 單字形、`⌘2` 多字元、`⌘3` 全部字。
- 在多字元中點一下字形就能查看替換字。支持豎排，點右鍵或使用 `⌘5` 切換，文字對齊和字體排印也在這裡。菜單欄「顯示方式」中還有更多選項。
- 在全部字中停下鼠標可以看字形信息，點兩下字形可以添加到已有文字中，在側邊欄中點一下字形還會在全部字中閃一閃。點右鍵可以找到「篩選特性」。
- 用 `⌘+`／`⌘−` 來放大或縮小字形，也可以使用觸控板撐捏。在多字元中還可以用 `⌥⌘+`／`⌥⌘−` 或橫著撐捏觸控板來放大或縮小邊距、用 `⌃⌘+`／`⌃⌘−` 或豎著撐捏觸控板來增加或減少行距。按 `⌘0` 恢復預設大小。
- 用陰影表示邊界框，包括字形寬度高度和排版行高行距，可以用 `⌘4` 隱藏。
- 有做暗黑模式，但要小心點到實心字形會眼瞎瞎喔。在菜單欄的「顏色」裡可以改字形、邊界框陰影和背景的顏色。調好的顏色可以點「儲存目前配色」，按住 `⌥` 可以刪除配色。
- 在菜單欄點「作為預設值」，可以記住目前的視圖、顏色、大小等預覽設定和窗口大小，以後每次都以當前選擇來開啟字體檔案。按住 `⌥` 可以改點「還原預設值」。

## 限制

- 側邊欄和全字篩選用的是自主研發的 GSUB 和 AAT 解析器，結果可能和 CoreText 整理過的不完全一致，但和字體內部一致。
- 字形名稱來自 CoreText，當 CoreText 沒有可用名稱時顯示 GID。
- 字寬數據來自 CoreText 水平 advance。
- 字高數據有 `vmtx` 時來自 CoreText 垂直 advance，無則使用 `sTypoAscender + sTypoDescender`，再無及多字元使用 CoreText `ascent + descent`。
- 多字元排版及其度量由系統 TextView 提供，不可控但反映 macOS 真實效果。因無法指定不 fallback，缺字只能在結果中剔除。
