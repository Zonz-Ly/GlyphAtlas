# Glyph Atlas

A native macOS inspector for the alternate glyphs, contextual substitutions, and ligatures a font provides for the text you type.

## Requirements

- macOS 11.0 or later

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
- Type one or more characters in the sidebar to analyze all associated glyphs, then select a glyph to view it on the right.
- The page shadow shows the glyph's defined width and height.
- Double-click a glyph, or select it and press `Return`, to replace the default glyph and show that glyph's substitution.
- Use key `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.

## Limitations

- Direct GSUB parsing covers single and alternate substitutions only; ligatures and contextual substitutions are discovered through CoreText shaping.
- Variable fonts are inspected at their default instance.
- Features or substitutions available only through private font tables, or not exposed by CoreText, cannot be enumerated.
- Glyph names depend on the font's glyph-name data (`post` table or CFF charset); when CoreText returns no usable name, the app shows `GID n`.
- Glyph width comes from the horizontal advance. When `vmtx`/`vhea` is present, glyph height comes from the vertical advance; otherwise it uses `ascent + descent`. The baseline uses the `vmtx` top side bearing when available, and `descent` otherwise.

---

一個原生 macOS 字體替換字形查看器：使用系統原生 API，輸入文字，查看字體為該文字提供的所有替換字形、上下文替換和連字。

## 系統要求

- macOS 11.0 或更高版本

## 使用

- 打開字體，也可以把字體拖到該 app 的窗口或圖標上打開，支持最近使用的文件。
- 在側邊欄中輸入單個或多個字符解析所有關聯字形，選擇一個字形在右側展示。
- 展示字形用陰影表示字形寬度和高度。
- 按兩下字形或選中字形後按 `Return`，可以取代默認字形，顯示該字形的替換字。
- 使用方向鍵 `↑`／`↓` 選擇上下字形，使用 `⌘↑`／`⌘↓` 選擇上下默認字形，使用 `⌥↑`／`⌥↓` 選擇字形列表中的第一個和最後一個字形。
- 使用 `⌘C` 複製選中字形的所有編碼字符。
- 鼠標在 Unicode 上靜置時顯示該 Unicode 標準規定的字符名稱。

## 限制

- GSUB 直接解析只覆蓋 single/alternate；連字和上下文替換通過 CoreText 排版發現。
- 可變字體只檢查默認實例。
- 只存在於字體私有表、或 CoreText 未暴露的特性無法枚舉。
- 字形名稱取決於字體的 glyph name 數據（post 表或 CFF charset）；CoreText 沒有可用名稱時顯示 GID。
- 字寬來自水平 advance。有 `vmtx`/`vhea` 時字高來自垂直 advance；否則使用 `ascent + descent`。基線優先用 `vmtx` 的 top side bearing，沒有垂直表時用 `descent`。
