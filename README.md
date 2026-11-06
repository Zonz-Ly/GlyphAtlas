[中文](README.cn.md)
# Glyph Atlas

A native macOS font and alternate-glyph inspector. Type text to see every alternate glyph, contextual substitution, and ligature the font provides for it, along with the typeset result and every glyph in the font.

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/62d2aca2-83aa-4f3f-ac30-e96c50b5aa45" />

<img width="712" height="512" alt="圖片" src="https://github.com/user-attachments/assets/da0c8b0d-6379-4665-b72f-7e3c42c1bddf" />

## Requirements

- macOS 12.0 or later.

## Support

- .ttf .otf .ttc .otc .woff .woff2 .dfont
- Chinese (Mandarin, Cantonese, Shanghainese, Changsha Xiang, and Teochew, in Simplified and Traditional scripts), Tibetan, Uyghur, Japanese, Korean, English, German, French, Spanish, Italian, Brazilian Portuguese, Russian, Vietnamese, Thai, Arabic, Hindi, Malay, Khmer, Latin, Esperanto.

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

- Extract the app from the ZIP created by the build script or downloaded from [Releases](https://github.com/Zonz-Ly/GlyphAtlas/releases).
- If macOS blocks the app from opening, open the built-in Terminal app, type `xattr -rc`, then **a space**, and drag the app into the window. Check that the app's file path has appeared, press Return, then open the app.

## Usage

- Use “Open At” in the menu bar to open a font directly from a Fonts folder. You can also drag a font onto the app icon or onto a window with a font already open, or set Glyph Atlas as the default app for opening font files. Recently opened items are supported.
- Use the menu bar to copy the font open in the current window to your user Fonts folder in one click. Hold `⌥` to copy it to the Fonts folder for all users.
- When you open a variable font, a variation panel appears beside the window controls. Drag it out to keep it open. Select a numeric value and use `↑`/`↓` or `⇧↑`/`⇧↓` to adjust it.
- Type one or more characters in the sidebar to see all associated glyphs. Use `⌥⏎` to insert a line break. You can also right-click and choose “Saved Text” to save the current text or quickly enter text you’ve saved before. Hold `⌥` in the menu bar to quickly delete saved text.
- Double-click a glyph, or select it and press `⏎`, to replace the default glyph and show its alternates. Hold `⇧` while doing this to add the glyph.
- Use `↑`/`↓` to move between glyphs, `⌘↑`/`⌘↓` to move between base glyphs, and `⌥↑`/`⌥↓` to jump to the first or last glyph in the list.
- Use `⌘C` to copy all encoded characters of the selected glyph.
- Hover over a Unicode badge to see the character name defined by the Unicode standard.
- Glyph Grid is the default. Right-click to switch views, or press `⌘1` for Single Glyph, `⌘2` for Characters, or `⌘3` for Glyph Grid.
- In the Characters view, click a glyph to view its alternates. Choose Vertical Layout from the shortcut menu or press `⌘5` to switch between horizontal and vertical writing. Text alignment and Typography are here too. The View menu in the menu bar has more options.
- In Glyph Grid, double-click a glyph to add it to the existing text. Clicking a glyph in the sidebar makes it blink in Glyph Grid. Right-click to find Filter by Feature.
- Use `⌘+`/`⌘−` to make text bigger or smaller, or pinch on the trackpad. In the Characters view, use `⌥⌘+`/`⌥⌘−` or a horizontal pinch to increase or decrease the margins, and `⌃⌘+`/`⌃⌘−` or a vertical pinch to increase or decrease leading. Press `⌘0` to restore the default size.
- The shadow shows the bounding box, including the glyph's width and height and the layout's line height and leading. Press `⌘4` to toggle Bounding Box.
- Dark mode is supported. Watch out when clicking a solid glyph, as it can dazzle you. You can change the glyph, bounding box shadow, and background colors under Colors in the menu bar. Choose Save Current Palette to keep your colors. Hold `⌥` to find Delete Palettes.
- Choose Use as Defaults in the menu bar to save the current view, colors, size, other preview settings, and window size. Font files you open later will use these settings. Hold `⌥` to choose Restore Default instead.

## Limitations

- The sidebar and the Glyph Grid filter use in-house GSUB and AAT parsers. They follow the font's own tables, so their results can differ from CoreText's processed results.
- Glyph names come from CoreText. When CoreText returns no usable name, the app shows `GID`.
- Glyph width comes from CoreText's horizontal advance.
- Glyph height comes from CoreText's vertical advance when `vmtx` is present. Otherwise it uses `sTypoAscender + sTypoDescender`. If those are unavailable, or in the Characters view, it uses CoreText `ascent + descent`.
- The system TextView provides layout and metrics for the Characters view, reflecting how macOS actually typesets the text. The app filters missing glyphs out of the preview because TextView has no option to turn off font fallback.
- Trackpad pinch gestures may occasionally get stuck due to a longstanding macOS issue. Here’s hoping Apple fixes it.
