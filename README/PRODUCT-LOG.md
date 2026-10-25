# Glyph Atlas Product Log

Working log for Glyph Atlas, kept next to the code. The user-facing README lives
in the upstream repository, <https://github.com/Zonz-Ly/GlyphAtlas>, which also
serves as the reference for how the project was originally written.

Glyph Atlas is a native macOS inspector for the alternate glyphs and ligatures a font provides for the text you type.

> Project root: this folder (`GlyphAtlas/`). `build.sh`, `README/`, `.gitignore`, `Sources/`, `Resources/`, `diagnostics/`, and `dist/` all live here; every path below is relative to it. `README/` holds this log, `COLLABORATION-NOTES.md`, and `GLOSSARY.md`. `.build/` is scratch output and is recreated by `build.sh`. `Sources.backup/` is the pre-2026-10-23 rollback snapshot.

The window is split into a full-height sidebar and a canvas. The title bar is hidden; the font name appears as a toolbar item beside the traffic lights. The UI is English-only.

## Documentation

- `PRODUCT-LOG.md` (this file): product behavior, decisions, measurements, and limitations; append when user-visible behavior changes.
- [`GLOSSARY.md`](GLOSSARY.md): current terminology, symbols, architecture, and boundaries; update when code or semantics change.
- [`COLLABORATION-NOTES.md`](COLLABORATION-NOTES.md): how to work with the owner, authorization, verification, pitfalls, and handoff.

These three documentation files are living documents. Successors may update them directly and do not need to report first; keep them current and handoff-ready. Do not create numbered copies. Code changes still require an explicit confirmation popup.

## Requirements

- macOS 12 or later (the multi-character view uses TextKit 2)
- Command Line Tools (a full Xcode installation is not required)

## Build

```bash
bash build.sh
open "dist/Glyph Atlas.app"
```

`build.sh` builds a universal binary (`arm64` + `x86_64`) by default and writes
`dist/Glyph Atlas.app`. To build only one architecture:

```bash
ARCHS=arm64 bash build.sh
ARCHS=x86_64 bash build.sh
```

The app is ad-hoc signed and has no third-party dependencies or network access.

## Window and input

- Native `NSSearchField` with the system bezel, no magnifier or clear button; single-line.
- `⌘←` / `⌘↑` move the insertion point to the start of the input; `⌘→` / `⌘↓` move it to the end.
- `Return` moves focus to the glyph list. `Option-Return` and pasted line breaks are stored as a marked `U+23CE` in the one-line field: the marker is visible inline in `secondaryLabelColor`, hidden from the glyph list, and becomes a hard line break in the multi-character view. Copying, cutting, or dragging a selection writes `U+000A` back to the pasteboard.
- Native source-list `NSTableView`.
- The sidebar starts at 200 pt and can be resized between 200 and 1000 pt.
- Default and minimum window size is 600 × 400 pt.
- The font name is a toolbar item placed before the sidebar tracking separator.
- Each font opens in its own window. Closing the last window does not quit the app.
- `⌘O`, the launch open panel, drag-and-drop onto a window, and drag-and-drop onto the Dock icon all open fonts.
- Dropping a font onto a window always opens a new window.
- **Open Recent** uses the system recent-documents list, shared with the Dock's Recent Items.
- There is no automatic reopening of the last font or restoration of font windows.
- The canvas can be dragged to move the window.

### Input field (2026-10-23, updated 2026-10-24)

The sidebar input is a `GASearchField`, an `NSSearchField` subclass whose
`GASearchFieldCell` forces a 9 pt text inset on both edges. The search and
cancel button cells are nil, so the field keeps the bezel without a magnifier
or clear button. The custom field editor, line-break markers, and selection
runs are unchanged.

macOS 27.2 (AppKit 2775.20) returned a negative text rect from
`NSSearchFieldCell` when both button cells had been set to nil:
`{-2, 6, 178, 20}` for a 182 × 28 field. The field editor was placed at that
rect and clipped at the field's left edge, so the text started at about
0.5 pt. macOS 14.8.7 returned `{9, 6, 164, 16}` for the same nil-button
configuration. `GASearchFieldCell` overrides `searchTextRectForBounds:`,
`titleRectForBounds:`, and `drawingRectForBounds:` to put both edges at 9 pt
while keeping the cell's vertical rect.

On macOS 14.8.7 the 9 pt text inset path (placeholder, typed text, ⌘A/Delete)
was verified; the cell's text rect and field editor frame are
`{9, 6, 164, 16}` for a 182 × 28 field. macOS 27.2 is pending an on-device
check; if the new cell's field editor ignores the overridden rects, the
fallback is a stock search field with its stock buttons.

## View modes

The `View` menu is shared by the menu bar and the main-view context menu.

| Menu item | Shortcut | Behavior |
| --- | --- | --- |
| Single Glyph | `⌘1` | The original per-glyph canvas. |
| Multi-Character | `⌘2` | Lays out the full input text in one canvas with automatic wrapping and hard line breaks. The text is an `NSTextView` using TextKit 2. Single-clicking a glyph selects its base glyph in the sidebar; sidebar selection highlights it, while double-click/Return uses the normal activation path. |
| All Glyphs | `⌘3` | Default. One equal-spaced grid of every GID in the font; no canvas or inset. Each cell centres the glyph's page (horizontal advance × ascent + descent), not its ink; the baseline is descent above the page bottom. `⌘+` / `⌘-` changes cell size and therefore the number of columns. Double-clicking an encoded cell appends its first Unicode character to the input and selects that GID. Revealing a glyph from the sidebar keeps the minimal scroll when its row is already visible and centres a row that is outside the viewport. Sidebar reveal blinks the accent colour (0.1 s on, 0.1 s off), holds it for 1 s, then fades over 0.7 s; double-clicking a cell to append uses one 0.2 s highlight and a 0.8 s fade. |

Common controls:

- `Show Metrics` (`⌘4`) hides the definition page and shadow while preserving the page inset and glyph position.
- `Vertical` (`⌘5`) toggles vertical writing and appears above `Text Alignment` in the View menu; it is enabled only in Multi-Character.
- Single: pinching or `⌘+` / `⌘-` scales the page at ×1.12 per key press; `⌘0` restores the default page (79.72% of the viewport, 10.14% side inset).
- Multi: `⌘+` / `⌘-` changes the text display scale (32 pt × 1.12^n, n = −10…20, ×1.12 per press); pinching changes the text scale too, keeping the page centre under the viewport centre. `⌥⌘+` / `⌥⌘-` changes the metrics/page size at ×1.12; those are AppKit alternate menu items, so no window-level key handling intercepts them. `⌘0` restores both text scale and metrics page.
- Multi uses one canvas, not one page per line. TextKit 2 decides line height, leading, column width, wrapping and the used bounds from the font's real metrics; the page is sized from those bounds.
- A line break (`U+000A`) starts a new line in horizontal writing and a new column in vertical writing; wrapped lines and hard breaks share the same line metrics.
- Multi supports left/center/right/justified alignment and horizontal/vertical writing. In vertical writing TextKit 2 applies the font's vertical forms and UAX #50 orientation (CJK upright, Latin and digits rotated) and places columns right-to-left. Horizontal text uses the font's normal kerning; ligatures are disabled (`NSLigatureAttributeName` = 0) and contextual alternates are disabled (`calt` = 0) so supported source characters stay visible and unligated.
- In vertical writing, a `‘`/`’`/`“`/`”` group that is not seeded uses the font's `vert` output when one exists; a seed affects only its own group. It is not substituted when that output is already the encoded vertical form (U+FE41/U+FE43 for `‘`/`“`, U+FE42/U+FE44 for `’`/`”`). The selected `vert` GID then goes through the same 字/A base-name rule as a seed, so the display copy may use 字 or A as its base string while the GID stays unchanged.
- Missing glyphs (base variant GID 0, not seeded, not a line break) are omitted while the controller builds the text and groups handed to the multi-character view. The filtered text and group ranges match, so the view does no filtering or offset mapping; the sidebar still lists the `.notdef` variant for inspection.
- Unencoded replacement glyphs are specified with `NSGlyphInfo`, so TextKit draws the selected GID in the normal text flow; no glyph is drawn by the view itself.
- In vertical writing the base character decides the seed's orientation. If the source character is not upright (UAX #50) and the selected GID is full-width (its advance equals the em or the advance of 字), the display copy uses 字 as the base so the glyph stays upright. If the source character is upright and the GID is narrow, it uses A as the base so the glyph turns. This substitution happens only in a private copy of the displayed attributed string; the input field is never modified. The GID is unchanged. `NSGlyphInfo`'s base string is rebuilt to match the substituted character because TextKit ignores a glyph info whose base string differs from the character.
- All Glyphs: `⌘0` restores the default grid scale.

## Glyph rows

Each row shows:

- the glyph drawn at its real size relative to the font's em
- the glyph name, or `GID n` when the font has no usable name
- the original OpenType feature tags that produced it
- Unicode code badges at the right edge, with the Unicode character name as a tooltip

Synthetic glyph names such as `gidNNN`, `uniXXXX.N`, and `uniXXXX_uXXXX` are replaced with the actual GID.

## Analysis

Text is split into composed-character groups. For each group the app collects:

1. direct GSUB single and alternate substitutions
2. results from shaping with each OpenType and AAT feature setting

It also enumerates contiguous substrings by context length, shortest first, and left to right within a length:

```text
ab, bc, cd, ..., abc, bcd, ..., abcd, ...
```

Each substring is shaped separately. A shape whose glyph cluster covers more than one source character becomes a **combination group** (ligature or contextual substitution):

- one group per source range
- multiple schemes for the same range are kept together
- combination groups are listed after all character groups, in scan order: shorter contexts first, then by source position, so a result found later is always below one found earlier (`ff`, `fi`, `fl`, then `ffi`)
- a contextual substitution that covers a single character stays a variant row of that character's group
- groups are rebuilt from scratch after every text change

Raw scan results are cached by content in `GATextScanModel`; a display group and a ligature group are range-bound and rebuilt per text. The cache is per font document and is discarded when the font changes. A ligature group still has no persistent identity beyond its current text range.

Line breaks are layout, not glyphs. Their character groups keep the text ranges intact but are hidden from the glyph list, and the substring scan treats them as boundaries: no substring crosses a line break.

Raw scans run off the main thread. Each text change reconciles the current text's complete desired context set against the content cache and the pending queue: still-valid pending subitems stay in their old items and are rebound to their new ranges, contexts that disappeared are dropped, and each group's missing items are appended after the old items. The current subitem always finishes; its result is cached by content and applied to every current position with that content, so a new text never waits for an old whole-text pass and never rescans cached content. There is no input-length limit.

The sidebar and the multi-character view receive the display groups after every model update and every completed subitem. The first publication uses `setGroups:`; later ones use `applyStreamedGroups:`. The multi-character text is rebuilt when a text change has finished its single-character scan pass, or when the seed signature changes. Combination groups appear in group⇒item⇒subitem order while the rest of the scan continues. The selected row is restored from its glyph key and text range without scrolling. Pending contexts that have not been scanned yet are simply absent from the display.

The first full pass is still quadratic in the number of contexts (the complete scan is required). Subsequent edits scan only contexts whose content is not cached, but the desired-set enumeration itself remains O(n²). Keeping the cache bounded for very long texts is future work.

AAT is used only to discover glyphs and substitutions. AAT type/selector names are not shown as feature sources. OpenType sources use the raw tag and value, for example `liga` or `aalt 2`.

## Single-character path (2026-10-23)

The current single-character path:

- `GATextScanModel` builds a `content → [1 字组 index]` index in `rebuildGroups`. Cached single-character results are applied through that index instead of scanning every group for each unique character, reducing the single-character part from O(n²) to O(n).
- A length-1 scan result is applied once, through the index, to every group with the same content. `aaaa` still produces four variants; the redundant first apply on the scan subitem was removed.
- `singleCharacterScanComplete` now treats "no pending length-1 subitems" as complete. This makes cached single-character text refresh the multi-character view.
- `clearScanDisplay` resets the multi-character signature and `scheduleAnalysis` advances the generation before clearing, so an old generation cannot write a stale signature or snapshot over the new text.

Measured on an isolated 1,000-character test (1,000 different CJK characters, one per line, PingFang SC, 100 append/withdraw cycles): `updateText` fell from roughly 220–225 ms to roughly 160 ms. The remaining cost is the O(n²) context enumeration in `desiredSubitems`; it was not changed in this cleanup. A 1,000-character single-paragraph app-level run was not performed because the initial multi-context scan is very slow.

Deferred: the `setTextScale:` same-value guard and merging `setGroups:` / `applyStreamedGroups:` were intentionally left out (the latter has different fallback, notify, and pending policies).

## All-glyph and sidebar page metrics (2026-10-24)

The all-glyphs grid used to centre each glyph's **ink bounding box**. The sidebar thumbnails did the same. Both are wrong for punctuation, quotes, and accents: they floated on the cell/icon centre line regardless of their typographic height.

The grid and the sidebar now use one page metric:

- page width: the horizontal advance (`hmtx`, raw font units)
- page height: `ascent + descent`
- baseline: descent up from the page bottom

The single-glyph canvas is unchanged: it keeps its `vmtx`/`vhea` vertical advance and top-side-bearing baseline. `GAFontDocument +pageForVariant:usesVerticalMetrics:` selects the mode; the canvas passes `YES`, the grid and the sidebar pass `NO`. The `NO` path does not read `vmtx`/`vhea`. The grid caches one `GAGlyphPage` per GID; each sidebar thumbnail computes it once in `setVariant:`.

Sidebar thumbnails keep their 32 pt/em glyph size. For fonts whose page is taller than the 34 pt icon (ThemeX Hiragino Sans is about 1.4 em), the glyph is drawn past the icon's bounds into the row's vertical padding, so descenders are not clipped. The icon does not draw the page rectangle; it only uses the page for the advance centre and baseline.

Measured at the default 44 pt all-glyph cell, against the old ink-centred layout:

| Change | ThemeX Hiragino Sans | Arial Unicode (no `vmtx`) |
| --- | --- | --- |
| comma | down about 14.5 pt | down about 15.5 pt |
| period | down about 12 pt | down about 13 pt |
| quotes / asterisk | up about 8.5–9.5 pt | up about 7–7.5 pt |
| digits, capitals, CJK | within 0.5 pt | within 1.5 pt (most unchanged) |

Cost: a page-metric cache miss remains sub-0.1 ms per GID on ThemeX Hiragino Sans; the `NO` path avoids the `vmtx` reads. The default window shows 49 glyphs; 1,000 visible glyphs cost tens of milliseconds once. Later frames and already-seen GIDs are cache hits. The cache is one 56-byte `GAGlyphPage` per GID (about 3.5 MB for a 62,000-glyph font) and is released when the font changes.

The single-glyph canvas was compared pixel-for-pixel before and after the shared-metric refactor for ThemeX Hiragino Sans, with a comma selected; the canvas region was identical. The sidebar thumbnail keeps its 32 pt/em size, so a page taller than the icon (ThemeX is about 1.4 em) draws into the row's vertical padding instead of clipping: the g descender is complete in the row.

## Selected glyph runs

Select a glyph and press **Return**, or double-click it.

### Encoded glyphs

The source text is replaced with the glyph's first Unicode character:

- a normal character variant replaces that character
- a ligature variant replaces the entire source range of the ligature
- if the glyph maps to several Unicode characters, activation still inserts only the first one; Copy keeps all of them

The new text is analyzed again and a new list is built. No selection run is stored.

### Unencoded glyphs

The source range is marked as a **selection run** in the input field's attributed string:

- one run covers the original character, or the complete ligature source such as `fi`
- the run stores the original substring, the exact glyph IDs, and feature labels for display
- the chosen glyph becomes the base glyph of a group displayed in place of the covered characters
- ligature groups and character groups overlapping the run are suppressed
- unlike an unseeded ligature group, the selection group replaces the covered characters in place
- analysis runs again immediately

Runs are ranges in the attributed text, not occurrence indexes. Inserting or deleting text before or after a run moves the run automatically. Editing inside a run changes its source text, so the run is dissolved and the text returns to normal character groups. Deleting a run's entire range removes it.

The input field keeps its native search-field appearance. User edits and pastes are normalized to plain text, so formatting copied from other applications is discarded; only the internal selection-run attributes are preserved.

### Shift activation (2026-10-24)

Hold Shift while double-clicking a glyph or pressing Return/Enter. The activated glyph is inserted as a new item immediately after its own source range; the glyph already at that position is not replaced.

- The anchor is the activated row's own source range, resolved by the same `sourceRangeForVariant:inGroup:text:` path as normal activation. The insertion point is `NSMaxRange(range)`.
- The source character for the new item is the text of that source range. A combination group contributes its whole source range.
- An encoded glyph inserts its first Unicode character as plain text and stores no run.
- An unencoded glyph inserts the source text with a `GAGlyphSelection` run carrying the exact glyph IDs and feature labels.
- The existing glyph's text, run, glyph IDs, and feature labels are unchanged.
- The inserted item is not selected or scrolled to; the list keeps the activated row selected. Normal activation still selects the glyph it produces.
- Repeated Shift activation from the same source group inserts at the same point, so later insertions appear closer to the source (reverse order). This is the current interaction, not a bug.
- Shift is read from the triggering event's modifier flags. Only Shift may be held among Command, Shift, Option, and Control; Caps Lock and function keys do not disable the mode.
- Shift+Return/Enter on the selected row behaves like Shift+double-click on that row: it inserts a copy after itself.
- If the variant has Unicode, the inserted character is a normal source character; it is not selected, so no pending selection waits on the clicked GID.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Return / Enter | Activate the selected glyph (same as double-click) |
| Double-click | Activate a glyph |
| Shift+Return / Shift+double-click | Insert the activated glyph after its own source range (Shift activation) |
| `⌘C` | Copy the actual Unicode character(s) of an encoded glyph |
| `⌘↑` / `⌘↓` (glyph list) | Move to the previous / next character group's base glyph |
| `⌘←` / `⌘↑` / `⌘→` / `⌘↓` (input) | Move the insertion point to the start / end of the input |
| `⌘1` | Single Glyph view |
| `⌘2` | Multi-Character view |
| `⌘3` | All Glyphs view |
| `⌘4` | Show Metrics |
| `⌘5` | Vertical writing (Multi-Character) |
| `⌘+` / `⌘-` | Zoom the active view; in Multi-Character this changes text size |
| `⌥⌘+` / `⌥⌘-` | Multi-Character: Metrics Zoom In/Out (page size) |
| `⌘0` | Reset the active view zoom (Multi-Character resets text and metrics page) |
| `⌘O` | Open fonts |
| `⌘W` | Close the window |

`Edit > Copy` also copies an encoded glyph's characters and is disabled for unencoded glyphs.

## Canvas

The canvas and detail panel use a flat titlebar-matched background: `#FFFFFF` in light appearance and `#3C3C3C` in dark appearance. The glyph is drawn with `#222222` in light appearance and `#EEEEEE` in dark appearance. The canvas keeps its default 79.72% page (10.14% side inset) and page shadow.

The single-glyph page and glyph are sized from real font metrics:

- page width from horizontal advance
- page height from the `vmtx`/`vhea` vertical advance when present; `ascent + descent` fallback otherwise
- baseline from the `vmtx` top side bearing, or `descent` when there is no vertical table
- glyphs are drawn at their real font-unit size and origin
- overhanging ink is not clipped

The multi-character page is the area of the `NSTextView` layout: in horizontal writing its width is the viewport page width and its height is the used text height; in vertical writing its height is the viewport page height and its width is the used column extent. The text view is transparent and sits over the page; the page shadow and background are still drawn by `GAMultiGlyphView`.

Horizontal writing expands the text view frame by the canvas side inset and sets `textContainerInset` accordingly, so ink can overhang the page. Vertical writing keeps the text view frame equal to `pageRect` and the inset zero: the vertical text view's bounds are rotated, and the inset-expanded frame moves `textContainerOrigin` off the page. Vertical ink overhanging the page is therefore clipped; the single-glyph canvas still draws overhang.

## Limitations

- Analysis is limited to the current input text and its contiguous substrings. It does not invent contexts that are not present in the text.
- GSUB is parsed directly only for single and alternate substitutions. Ligatures and contextual substitutions are discovered through CoreText shaping.
- GID-level analysis (`analyzeGlyphIDs:`) covers GSUB single/alternate substitutions only.
- AAT substitution results are not labeled with AAT type/selector names.
- Variable fonts open at their default coordinates and can be adjusted through the variation popover; substitution discovery includes the union of GSUB FeatureVariations branches and stays cached as axes change.
- Features or substitutions available only through private font tables or not exposed by CoreText cannot be enumerated.
- Glyph names depend on the font's glyph-name data (`post` table or CFF charset); when CoreText returns no usable name, the app shows `GID n`.
- The multi-character view requires TextKit 2 (macOS 12 or later).
- An unencoded replacement glyph is specified with `NSGlyphInfo`. Only the first GID of a multi-GID variant is drawn. In vertical writing a full-width GID on a rotated source character is rebased to 字, and a narrow GID on an upright source character to A, so the glyph's orientation follows its design; this rebasing applies to single UTF-16 characters and only in the display copy.
- Vertical ink that overhangs the multi-character page is clipped by the text view; horizontal keeps the inset margin. The single-glyph canvas still draws overhang.
- Browser-only ligature groups (`insertedLigature`) are not substituted in the multi-character view; the source characters are still shaped by TextKit.
- Sidebar thumbnails keep their 32 pt/em glyph size. When the page is taller than the 34 pt icon, the ink is drawn into the row padding instead of being scaled; this was verified on macOS 14.8.7.
- Shift activation inserts the first Unicode character for an encoded glyph and stores no run, so the exact clicked GID is not pinned. For an unencoded glyph it stores the run.

## Reference

- [Terminology and API glossary](GLOSSARY.md)
- [Collaboration notes](COLLABORATION-NOTES.md)

## Diagnostics

- [Diagnostics notes](../diagnostics/README.md)
- [I.Ming data](../diagnostics/I.Ming-info.txt)
- [PingFang data](../diagnostics/PingFang-info.txt)
- [Fonts without vmtx](../diagnostics/no-vmtx-fonts.txt)
- [CJK hmtx/vmtx measurements](../diagnostics/cjk-vmtx-fonts.txt)
- [Diagnostic tool source](../diagnostics/inspect_font.m)

## Project layout

```text
GlyphAtlas/
  Resources/Info.plist
  README/
    PRODUCT-LOG.md
    COLLABORATION-NOTES.md
    GLOSSARY.md
  Sources/
    GAAppDelegate.{h,m}           app lifecycle, menus, open panels, recent fonts
    GAFontTypes.{h,m}             shared font UTType helpers
    GAFontEngine.{h,m}            CTFont/CTFontDescriptor wrapper, GSUB parser, shaping
    GAMainWindowController.{h,m}  window, scan-model wiring, selection runs
    GATextScanModel.{h,m}         incremental text scan model, content cache and queue
    GASidebarViewController.{h,m} input field, glyph table, shortcuts
    GAGlyphViews.{h,m}            glyph thumbnails, Unicode badges, row views
    GAViewMode.h                  all/multi/single mode enum
    GAGlyphCanvasView.{h,m}       single-glyph canvas
    GAMultiGlyphView.{h,m}        wrapping multi-character canvas
    GAAllGlyphsView.{h,m}         all-GID collection grid
    GADetailViewController.{h,m}  mode container
    GAUnicode.{h,m}               ICU character names, scalar-to-string conversion
```

## Variable font resources, discovery and controls (2026-10-25)

Variable-font instance descriptors collapse into resources using a pure CoreText comparison: common non-default coordinates, then all defaults, then CFEqual. One resource opens directly at its defaults; multiple resources still present the style chooser. Static collection faces remain separate.

The toolbar button is called Variable / 可變. Its actual outer frame is square (26×26 pt on this machine, including native alignment insets), with secondaryLabelColor and AppKit's native pressed appearance. The popover has the resource's presets, followed by 48pt axis rows. Labels and numeric fields align left/right; popup and slider alignment edges match. Numeric fields grow with displayed or edited digits (tested 39→72pt). Constraints let controls follow panel width. The attached NSPopover has no native user resize affordance, so no custom resize handle was added. Public detachment delegation supplies a separate native horizontally resizable NSPanel, minimum width 240pt and fixed height, with live controls and normal close lifecycle.

The inspector shows all substitutions, rather than applying conditional substitutions to the selected single-glyph page. Discovery scans the default coordinates and representative points of every supported reachable FeatureVariations branch, merges the results, and caches the union by text content. Condition-only single/alternate lookup outputs are also collected directly. The selected literal GID remains fixed as axes change: k stays k; selecting k.jump explicitly keeps k.jump even below the condition threshold. Multi-character layout still follows CoreText at the current coordinates.

Coordinate changes rebind the existing glyphs and metrics. They do not change the list's members/order, rescan content, reload the table or issue a selection-restoration jump. Existing visible cells receive new fonts, and offscreen row models are updated. Input changes, activation and newly discovered rows retain the established list-update rules. The all-glyph inventory is installed once per window; the old resource-switch/reset-to-top path was removed. Its font metrics cache is invalidated without moving the scroll origin.

Validation:

- Futura100CHI-Var 6 descriptors → 1 resource; temporary Futura/New York TTC 20 descriptors → 2 resources; Helvetica retains 6 faces.
- k/Q/e and their .jump counterparts are present at default coordinates. After incremental typing, every axis region retains identical inventory/order/base GIDs; coordinate changes perform zero new raw scans.
- Native window instrumentation: changing 400→650 retains selected k, and explicitly selected k.jump remains selected at 300. Zero raw scans, zero NSTableView.reloadData calls and zero selectRowIndexes calls during the coordinate refresh; sidebar and all-glyph scroll positions are unchanged.
- Panel programmatic widths 320→480 and native detached width 560 retain aligned controls; input width follows digits; detach controls and closing are connected. Attached native resizable flag is false.

Representative-point evaluation currently covers Condition Format 1 and avar 1. Direct single/alternate rules remain enumerable for other formats, but their conditional contextual branches are not guaranteed to be discovered. Existing long-text/context and cache-growth limits remain.

### Native Popover detachment correction (2026-10-25)

The user rejected the custom detached NSPanel: the original request allowed skipping width resizing when AppKit does not support it. Removed detachableWindowForPopover: and the separate panel/content-controller lifecycle. Only popoverShouldDetach: remains; AppKit supplies the native detached popover with its original appearance and content. The Variable button brings an already detached popover forward, and closing the main window closes the popover. No window style overrides or custom resize affordances are added. This supersedes the custom-panel behavior and validation described above.

The user will perform testing from now on. This correction is built and packaged without automated tests or UI verification.

### VF control layout follow-up (2026-10-25)

The numeric fields return to a fixed 64pt width. The field editor handles Up/Down as ±1 and Shift+Up/Down as ±10, using the edited number and the existing axis bounds and coordinate publication path. Named-instance titles now use CoreText's localized style name instead of the full font name.

The native popover keeps an empty title. Before detachment its content reserves the system titled-window height; after native detachment its outer frame keeps the attached window height, and the layout consumes the corresponding reservation. No custom detached window or window-style change is introduced.

Axis rows use native control intrinsic heights, baseline alignment, and system spacing. The scroll document's layoutMarginsGuide protects slider/field edges from clipping. The Variable button uses a native toolbar bezel in a fixed 26×26pt wrapper; its frame directly fills that wrapper, independent of alignment-rect constraints. Its image is unchanged.

Per the user's instruction, this follow-up is built and packaged only; no tests or UI verification are performed.

### VF appearance correction (2026-10-25)

At the user's request, the Variable button returns to its original borderless native appearance. The fixed square wrapper, explicit toolbar bezel, and forced button dimensions are removed. The numeric field width changes from 64pt to 66pt. Presets use CTFontCopyName with kCTFontStyleNameKey rather than CTFontCopyLocalizedName, so the app does not request system-localized style names. The space above the preset popup is reduced by 18pt in the attached and native detached layouts.

This change is built and packaged without tests or UI verification, as requested.


## 2026-10-25 — Isolated GSUB and AAT discovery replacement (historical HarfBuzz branch)

The experimental copy replaces CoreText feature-font scanning with statically linked HarfBuzz 14.5.0. The resource index reads GSUB lookup widths, nested lookup references, GDEF filtering data, FeatureVariations replacements and AAT chain feature masks. Execution covers all GSUB lookup types and morx/mort state machines; Unicode preparation, clusters and positioning come from the same engine. CoreText remains the font-table and drawing API; native TextKit remains responsible for the multi-character layout.

Each paragraph is one model query. Additional GSUB windows are derived from lookup context; AAT windows stay inside unsafe-to-break dependency islands. Default execution, each feature/selector value and every FeatureVariations record contribute options. Optional setting combinations are not exhaustively enumerated. Axis changes preserve the discovered GIDs and order, only rebinding fonts and literal positions. Literal layout removes substitution tables and verifies that positioning does not change the selected sequence.

The replacement also fixes related data loss: multi-GID seeds now execute as complete sequences and expand into per-GID NSGlyphInfo runs in the private display string; their hit map still points to the original input. Activating a multi-GID result preserves the sequence. Zero-output substitutions have an explicit empty row. Equal output GIDs with different ligature source spans remain distinct from each other and from the final character's base.

CLI verification includes explicit-format original fixtures for GSUB 1/2/3/4/5/6/7/8, nested alternate values, filtering flags, mark sets, mark attachment classes, three FeatureVariations records, variable advances, both static and multi-VF TTC resources, and malformed tables. morx/mort each exercise rearrangement, contextual substitution, ligature, noncontextual substitution and insertion. Model checks cover repeated text, supplementary UTF-16, combining marks, edits, clear/restore, axis rebinding and shared output GIDs. Display-data checks inspect actual CoreText output and the source map without creating a window or NSApplication.

The requested installed fonts are checked directly: ThemeX Hiragino Sans alternates, LucidaSubmono contexts, and Zapfino's morx ligatures. Representative whole-sequence GIDs agree with the independent CoreText CLI oracle. Actual Futura100CHI-Var FeatureVariations are additionally checked. Old-vs-new per-group GID/range comparison on Hiragino `邊`, Lucida `Objective-C`, Zapfino `ffi fi st`, and a plain 26-letter fixture loses no options. Model query counts change 65→11, 38→6 and 351→27 respectively. Query reduction does not imply every short case is faster: an early cold Zapfino run took roughly 34 ms versus 17 ms in Old.

Measured CLI examples before GUI validation: 1000 distinct characters in a plain fixture completed in about 80 ms; 190 Lucida characters about 1.3 s; 105 Zapfino characters about 0.2 s. These are model/engine measurements, not app end-to-end timings, and remain font dependent. Pathological AAT state machines can make an entire run interdependent; there is no arbitrary context cutoff.

All GUI/visual acceptance remains with the user. Horizontal/vertical TextKit rendering, wrapping, click selection, VF selection retention and Popover interactions were not exercised by automation.

**本次决策：** 用户保留原 Glyph Atlas 工作目录自行修改，实验只在 GSUB 副本进行；Old 保持复制时状态供后续三方合并。后来明确加入 morx/mort 支持。没有对原目录回写，也没有推送远端。


Final CLI record for this experiment: 331 engine/resource assertions, 27 model assertions and 7 seed-display data assertions passed. Forty original fixture fonts passed AddressSanitizer and UndefinedBehaviorSanitizer. Thirteen localization catalogs and README Help remained consistent. Universal arm64/x86_64 compilation produced no warnings, minimum deployment target is macOS 12.0, and the clean ZIP extraction passed strict code-signature verification. Runtime CLI checks ran on arm64; x86_64 was compiled but not executed. Old's 81 baseline files were checked byte-for-byte unchanged.


## 2026-10-25 — Strip unused HarfBuzz code from the release

Keep HarfBuzz in its upstream single-translation-unit amalgamation and compile it with size optimization, full LTO, function/data sections and hidden inline visibility. The app participates in LTO and links with dead stripping; release local symbols are removed. The shaping configuration is unchanged. This reduces the unsigned universal link output from 3,766,992 to 1,899,136 bytes (49.6%) and the ZIP from 1,727,167 to 1,173,542 bytes (32.1%). The two native executables are 883,328 bytes for arm64 and 1,000,112 bytes for x86_64. Before local-symbol removal, unused Math, Meta, buffer-serialization, face-builder and style entry points were already absent, confirming actual unused implementation removal. Link maps and before/after measurements remain under `.build/`.

The use of HarfBuzz is an implementation choice, not a requirement for Glyph Atlas. The old parser can be extended into a dedicated GSUB/AAT interpreter; doing so transfers lookup execution, state-machine handling, source tracking, malformed-table handling and compatibility maintenance to this project. Our own discovery policy, range/index/cache logic and FeatureVariations union remain separate from HarfBuzz's shaping execution.

The signed executable in the delivered app is 1,950,048 bytes; this includes the final signing data. All 331 engine/resource, 27 model and 7 display-data assertions passed with the optimized CLI build. Both release architectures compiled without warnings; no GUI or ZIP extraction checks were performed for this change.


## 2026-10-25 — Self-written GSUB/AAT branch and literal neighbor queries

Work is isolated on local `experiment/self-written-substitution`, based on `73a999d`. The preceding HarfBuzz implementation remains on `experiment/gsub-aat`. This branch removes its vendored source, compilation and license-copy path. No changes were pushed or copied into the user's active project or Old.

The new C++17 core separates checked immutable byte views, cmap/GDEF, OpenType programs, GSUB execution, AAT execution, glyph/source tracking, variation data and positioning. Objective-C++ adapts selected-resource table bytes and native CoreText advances. System ICU supplies Unicode properties and bidi levels. There is no production CTLine/CTRun discovery or external shaping engine. All code participates in size optimization, LTO and dead stripping.

GSUB lookup types 1–8, all contextual formats and nested length-changing actions execute in our interpreter. AAT supports both morx/mort and all legal substitution types, including all 16 rearrangement verbs and end-of-text mark/ligature/insertion actions. GSUB discoveries keep the union of all FeatureVariations branches; axis changes rebind native metrics and positioning without rescanning or changing literal selections.

The user's additional requirement is implemented through the full data path: a selected unencoded GID participates in paragraph discovery with its neighbors. Text, relative source ranges and complete selected GID sequences define query/cache identity. A selection change with unchanged text schedules the affected paragraph; stale work from an earlier GID cannot populate the new query. When one part of a multi-GID seed ligates with a neighbor, overlapping sources form one atomic candidate and preserve the surviving GIDs. No Unicode placeholder or temporary cmap is needed.

`GADisplayGroups` now builds the same row data for the UI and CLI tests, independently of windows. The old exclusion of any ligature intersecting a selection has been removed. New combinations crossing a selected source and contextual changes on the selected glyph itself appear in the list. Only identical output/source identities are deduplicated; CoreText's old reachability is not a display filter. Optional feature settings remain individually enumerated; this is not an exhaustive Cartesian product of every glyph alternative and feature combination.

Validation: 331 engine/resource assertions, 373 additional layout assertions, 46 model assertions and 7 display-data assertions passed. Pure C++ checks include 31,756 assertions over 24,731 truncated/mutated table executions. AddressSanitizer and UndefinedBehaviorSanitizer passed 103 self-generated fixture fonts and the literal-neighbor row path. The requested Hiragino Sans, LucidaSubmono, Zapfino and actual Futura FeatureVariations samples pass. An additional 147 same-resource real-font strings agree with CoreText; one Lucida case that invokes another font's fallback is excluded from that comparison. A separate earlier 148-string comparison with the saved HarfBuzz executable had no GID differences. The original CoreText scanner comparison loses no options on the recorded samples; it is a regression oracle, not an output filter.

Performance findings: reverse alternate-family lookup is indexed once per resource rather than scanning all alternate sets on every query. The Hiragino 60-character example improved from about 2.3 seconds in the initial own-engine draft to about 107 ms. Query identities are immutable and cached per subitem, avoiding repeated allocation during queue completion. Current CLI model examples: 1,000 distinct plain characters about 74 ms, 190 Lucida characters about 80 ms, and 105 Zapfino characters about 218 ms. These are font-dependent model timings, not GUI end-to-end measurements.

Universal arm64/x86_64 builds complete without warnings, targeting macOS 12.0. Final unsigned universal link output is 1,027,776 bytes, signed app executable 1,078,688 bytes, and ZIP 706,289 bytes. The previous optimized HarfBuzz branch measured 1,899,136 / 1,950,048 / 1,173,542 bytes respectively. Both linker maps and exported symbols contain no HarfBuzz. Old's 81 baseline files remain byte-for-byte unchanged.

Runtime tests ran on arm64; x86_64 was compiled only. No GUI, NSApplication smoke test, app launch, installation or ZIP extraction verification was performed. GUI acceptance remains with the user. Full specialized script shaping and advanced positioning formats have explicit limits in GLOSSARY; supported lookup types are not a claim of complete HarfBuzz behavior equivalence.


## Context-independent glyph candidates and sidebar fixes — 2026-10-25

A GSUB catalogue now follows feature-reachable lookup actions for each queried input GID, across every FeatureVariations branch. Context actions retain the affected input position: LucidaSubmono `W` lists `W.w0` and `W.w1` without typing `i`, with `calt` provenance, and excludes the neighboring `i.t1`. Literal unencoded seeds use the same catalogue. Potential single-glyph candidates keep a single source range; actual cross-character combinations still require execution against the real paragraph/selected GIDs. This is a table-edge catalogue, not general symbolic execution of every combination; complex ambiguous nested length-changing programs and AAT state machines still depend on the actual-context executor. The detailed boundary is recorded in GLOSSARY.

Default/base results retain recorded feature sources through discovery, model merging and selection display. Known tags replace synthetic `actual`, and source labels are displayed verbatim in all languages. The old `actual` localization key was removed from all thirteen catalogs. `actual` is an application fallback, never a claimed GSUB feature.

The sidebar table uses a frame-sized document view, invalidates delegate row heights after reload, realizes its last row, and uses NSClipView's own bounds constraint for scrolling. No GUI was used; the user will verify actual long-list scrolling.

CLI validation: 351 substitution/resource assertions, 373 additional layout assertions, 46 model assertions, 7 display-data assertions, and 31,751 core checks over 24,731 deterministic truncated/mutated executions. ASan/UBSan passed 103 fixture fonts and selected-GID neighbor paths; mutation tests now exercise the new catalogue too. All thirteen localization catalogs pass with 75 strings plus one plural entry. Old's 81 baseline files remain unchanged.

The universal release built without warnings for arm64 and x86_64 (only arm64 execution was tested). Unsigned executable: 1,044,448 bytes; signed bundle executable: 1,111,744 bytes; ZIP: 717,817 bytes. The temporary staging bundle passed strict signing verification before archiving. After copying back to this FileProvider directory, FinderInfo metadata is reattached to the loose app root and a second strict check there rejects that metadata; clearing it did not prevent reattachment. The ZIP was created directly from the verified staging app; no extraction validation was performed, as requested. No GUI, installation or push occurred.

A separate optional cleanup audit is in CLEANUP-REVIEW.md; the four items are awaiting the user's selection and were not silently folded into these fixes.


## Four approved cleanup items — 2026-10-25

The user approved all four items in CLEANUP-REVIEW.md. Removed the unused hasFeatureVariations properties/getters. The scheduler now allocates only occupied query-length buckets in ascending order, retaining in-flight identities, old-batch priority and content caches; a 10,000-character paragraph allocates two buckets rather than 10,000.

Removed OpenType::family and both duplicate feature/lookup walks in the facade. Forward single/alternate mappings and reverse alternate siblings now share the per-GID catalogue/cache. A directFamily classification preserves direct-family queries on default-shaped base GIDs without treating nested contexts as an arbitrary transitive closure. Alternate index provenance, original-input GDEF filtering and the queried sequence's other components remain intact. A previously missing sibling option on a multi-GID text seed is now consistent with literal-GID discovery.

CLI-only featureSpecifications and shapeText methods, plus their AAT source-name adapter, are conditionally compiled under GA_FONT_LAYOUT_TESTING. CLI/sanitizer builds use explicit test mode and separate object directories; release defaults to production mode. The compile configuration fingerprint also invalidates reused objects when flags/mode change. A failed configuration transition invalidates the old fingerprint before compilation. Both actual release slices lack the three removed/test-only Objective-C selectors; the CLI retains its two test interfaces. Tests/check-release.py records this artifact-level check.

Validation: 129 before/after queries lost no candidates or sources (128 unchanged, one gained the correct prefixed sibling); 352 substitution/resource assertions, 373 additional layout assertions, 52 model assertions, 7 display-data assertions and 31,755 core checks over 24,731 truncated/mutated executions passed. ASan/UBSan passed 103 fixture fonts. Same-directory release → test → release compilation correctly changed method availability. All thirteen catalogs still pass; Old's 81 baseline files remain unchanged.

Universal arm64/x86_64 build completed without warnings. Unsigned executable: 1,027,744 bytes (was 1,044,448); signed executable: 1,078,656 (was 1,111,744); ZIP: 708,137 (was 717,817). The staging app passed strict signing verification before ZIP creation. The existing FileProvider metadata behavior of the copied loose app is unchanged; the ZIP comes from the verified staging bundle. Only arm64 was executed. No GUI, installation, ZIP extraction or push was performed.


## Contextual forms versus ligatures — 2026-10-25 user clarification

Only the queried glyph's contextual forms should appear without typing their surrounding context. Ligatures require the complete consumed input sequence. Removed type 4 output enumeration from the per-GID catalogue, including extension and nested-context calls; actual GSUB/AAT execution continues to discover matching ligatures with complete source ranges. No glyph-name or feature-tag heuristic is used. LucidaSubmono W still lists its W.w0/W.w1 calt forms without i; Zapfino f/i alone do not list fi, while fi input does. Literal and unencoded GID seeds obey the same rule.

Added CLI tests for incomplete/complete direct and extension ligature input, AAT morx/mort fi, literal GID sequences, and actual Zapfino. A pure-core test constructs a contextual root calling a nested ligature, proving single-glyph catalogue exclusion while complete input still executes. Model checks again require no ligature candidate at all before selecting the necessary unencoded input; the earlier weaker combination-only helper was removed.

Validation: 378 substitution/resource assertions, 373 layout assertions, 52 model assertions, 7 display-data assertions, 31,759 core checks and 24,731 deterministic mutations passed; ASan/UBSan passed 103 fixture fonts. Thirteen localization catalogs and the release-selector audit pass. Universal arm64/x86_64 build has no warnings; unsigned executable 1,027,744 bytes, signed 1,078,656 bytes, ZIP 707,818 bytes. Staging-signature verification passed; the ZIP comes directly from staging. No GUI, installation, extraction check or push was performed. The four approved cleanup items remain complete in fbf61ae; the clarification is a separate following commit.

### VF numeric field width (2026-10-25)

The user increased the fixed numeric field width from 66pt to 70pt. No other behavior changed. Built and packaged only; no tests or UI verification.

### VF spacing adjustment (2026-10-25)

Set the toolbar stack spacing between the Variable button and font name to 0pt. There is no separate NSStackView spacing for glyph names; their existing constraints are unchanged. Reduce the bottom whitespace inside the variation-axis scroll document by 18pt, through the last row's bottom-margin constraint so the content fitting height shrinks accordingly. Built and packaged only, without tests or UI verification.

### VF zero vertical spacing (2026-10-25)

Set both the numeric-field-to-slider vertical spacing and the slider-to-next-axis vertical spacing to 0pt, replacing their previous half-system-spacing constraints. Other spacing remains unchanged. Built and packaged only; no tests or UI verification.

### VF fractional system spacing (2026-10-25)

Set numeric-field-to-slider, slider-to-next-axis, and scroll-document-top-to-first-axis spacing to 0.25 times system standard spacing. Set last-axis-to-document-bottom spacing to 0.5 times system standard spacing, replacing the previous bottom margin minus 18pt. Horizontal margins and the preset popup top reservation are unchanged. Built and packaged only, without tests or UI verification.

### VF document edge margins (2026-10-25)

Set the first axis top to the document layoutMarginsGuide top minus 10pt, and the last axis bottom to its bottom plus 10pt, reducing both system document edge margins by 10pt. The two internal vertical gaps remain 0.25 times system standard spacing. Built and packaged only, without tests or UI verification.

### VF bottom and toolbar spacing (2026-10-25)

Reduce the last-axis-to-document-bottom gap to the system bottom margin minus 15pt. Restore the toolbar stack spacing between the Variable button and font name to 5pt. Other spacing remains unchanged. Built and packaged only; no tests or UI verification.

### Independent VF button spacing (2026-10-25)

Set the font title stack default spacing to 0pt and override only the spacing after the Variable button to 5pt with NSStackView setCustomSpacing:afterView:. No additional stack or button styling is introduced. Built and packaged only; no tests or UI verification.

### Revert independent VF button spacing (2026-10-25)

The user requested the immediately previous version. Restore the font title stack spacing to 5pt and remove the custom spacing override after the Variable button. Other changes, including the document bottom system margin minus 15pt, remain unchanged. Built and packaged only; no tests or UI verification.


## Complete query pipeline, native display controls, and source consolidation — 2026-10-25

Replaced per-character/paragraph jobs and text-window rediscovery with one complete query and one publication. GSUB collects overlapping/nested matches directly; AAT enumerates productive state origins/end actions and propagates candidates through subsequent subtables. The 220-case pre-refactor comparison initially found four Zapfino misses; targeted fixes restored all outputs/sources in those four cases. Full-input discovery can still be expensive: the recorded Zapfino 105-character case rose from about 237 to 555 ms, while plain 1000 characters improved from about 78 to 21 ms. These are CLI measurements, not GUI timing guarantees.

Both native display switches default OFF (context ⌘5, ligatures ⌘6, vertical ⌘7). Context menus hide unsupported text/alignment controls. TextKit 2/NSTextView is unchanged. Click prediction executes our own rules using TextKit line boundaries, then selects by exact GID sequence plus consumed source range. Fixed NSGlyphInfo seeds remain atoms; existing vertical curly-quote overrides remain. Runtime CoreText shaping was rejected by the user and is absent from production; CLI references retain it. The quote check tests source/GID projection, not raster equivalence to a standalone vertical CTTypesetter.

Sidebar structural updates preserve the visible row anchor; width changes do not reveal old selections. All-glyph append still selects and reveals its exact result. Removed the synthetic actual fallback after it accidentally labeled every base in the unified pipeline; missing provenance is now empty, known feature/selector sources remain.

Merged the user's original VF panel changes with Old as baseline (0514c8f). Sources is flat including former FontLayout core files. GATextDisplay combines seed-display and native-font settings; GASidebarInput owns input editing/marker conversion/normalization separately from the list controller. Removed empty Vendor metadata remnants. Tests and scripts remain development/build support and are not copied into the app. This snapshot still uses a C++ core; the user subsequently requested a pure Objective-C rewrite, which follows from this checkpoint.

Targeted validation: 327 layout/hit checks (including four own-only vertical quote projection checks), 74 atomic model checks, 16 sidebar/input checks, 7 seed-display and 13 native display-setting checks; 13 catalogs with 77 strings/plural each. Earlier in this refactor, ASan/UBSan passed 103 fixtures and 31,675 core checks over 24,731 mutations; not rerun after source-only consolidation. Universal build and release-selector audit pass without warnings. Old's 81 files and original merge snapshot hashes are unchanged. No GUI, installation, ZIP extraction or push.


## Restore C++ performance baseline and preserve Objective-C backup — 2026-10-25

The user reported a stall at roughly 100 characters and explicitly selected restoring the C++ core, while retaining the complete Objective-C version as a backup. The prior Objective-C rewrite is preserved in local branch backup/objective-c-core-2026-10-25 (c9788b5), plus the sibling outputs/Glyph Atlas ObjC Backup directory containing all tracked source and the original ZIP. BACKUP.json records the commit and ZIP SHA256. Backup contents and archive hash were verified without extracting the ZIP.

Current Sources exactly match a5ebe1a: C++17 parsed core, Objective-C++ adaptation, Objective-C App/UI, all flat. This keeps the original VF panel merge, complete query publication, TextKit 2 click mapping, SidebarInput/TextDisplay consolidation and empty missing-source labels. Build configuration changes now discard obsolete .o files before recompiling, so Objective-C-only translation units cannot leak into the restored C++ link.

Measured model query for Zapfino “office affine flower ” repeated five times (105 characters): the pure Objective-C version took 4379.4ms; restored C++ took 541.5ms with the same 785 variant rows. Earlier C++ measured 549.5ms on the same sample. This corrects the language-port regression; it does not resolve all long-input algorithm costs. The 420-character version exceeded a 12-second bound in both implementations. No claim that C++ alone makes every long query immediate.

Necessary validation only: 74 atomic model and 16 sidebar/input checks pass, restored-source/backup/Old hash checks pass, release selectors absent in both actual architectures. Universal arm64/x86_64 build completes without warnings. Signed executable 1079296 bytes; ZIP 712012 bytes. No GUI, native-shaper matrix, full mutation scan, installation or ZIP extraction verification. All changes and backup branches remain local.


## Native display defaults, vertical hits, and minimal row reveal — 2026-10-25

Both contextual alternates and ligatures now default ON in the main-window state and the multi-character view. Contextual alternates configure the displayed font descriptor's OpenType calt feature (kCTFontFeatureSettingsAttribute), used by NSFontAttributeName. Ligatures use NSLigatureAttributeName 0/1 on the attributed display string. TextKit 2/NSTextView remains the display engine.

Vertical text always takes the existing rule-based layout-hit path, even when both optional switches are off; this fixes the ordinary vert/vrt2 GID link previously bypassed by the base-glyph fast path. Explicit fixed-GID seeds and curly-quote display overrides are unchanged.

The user superseded the earlier scroll-unification approval with a narrower requirement. Preserve all original group scrolling and activation policies. Only after selectGlyphIDs:textRange: completes its existing group reveal, check whether the selected row's bottom is below the visible bottom and align that row bottom if necessary. No new global scrolling policy, removal of SelectedToTopIfNeeded, or anchor-refresh change is included.

Option+Enter was investigated only. The user confirmed inserting at the front or middle. Hiragino's ten-character example retains exactly 49 rows and identical GID/provenance/name/Unicode metadata after newline insertion; only source ranges shift (10 groups for front insertion, 5 for middle, 0 for trailing insertion). updateGroupsWithSameRows: rejects changed ranges. restoreScrollAnchor: then searches the old range, can resolve the preceding group, and falls back to that group's base row. The controller test double reproduced viewport y 1638 → 1330 with identical row counts and no explicit reveal; trailing insertion stayed 1638. The cause is stale source-range identity, not newly added glyphs. The user requested no fix yet, and these paths remain untouched.

Necessary checks: 20 sidebar/input state assertions, including unchanged legacy group and activation rules plus the new tall-group TextView link, pass. Existing 327 targeted layout/hit checks pass; the broad native-shaper matrix and mutation suite were not rerun. Universal arm64/x86_64 build has no warnings and release-selector audit passes. GUI behavior remains for the user to verify; no app launch, installation or ZIP extraction.


## Independent native-feature trial and range-only sidebar updates — 2026-10-25 (source only)

At the user's request, keep the native NSLigatureAttributeName channel at 1 and move both optional switches into the displayed font. OpenType fonts receive separate calt and liga/clig values. AAT fonts receive explicit ContextualAlternates and CommonLigatures selectors, selected by CTFontHasTable without reading table data. This is a trial of native-feature precedence, not a claim of verified independence on all fonts. Defaults remain ON; explicit glyph seeds and layout prediction are unchanged.

Fixed the reported unchanged-list case of Option+Enter: absolute source locations no longer force a table reload. The rebind gate still checks relative group boundaries, source text/range lengths, seed/combination/base/ligature flags and visual row metadata. It installs new source ranges and updates the selected range without selecting or scrolling. A different source/structure still triggers normal publication and existing pending activation behavior. The previous minimal TextView bottom-reveal addition is preserved verbatim.

Updated all test callers for the display-font signature and added range-shift/repeated newline insertion/removal assertions. The user explicitly deferred builds to the next round: no compiler invocation, binary test, GUI, app build or ZIP packaging was performed. Existing dist artifacts belong to the preceding revision. Source diff and SDK identifier checks only; tests are prepared, not passed.

Research on vrt2 found the current OpenType definition and first-hand 2019 reports of NSTextView/TextEdit using vrt2 in preference to vert. This is historical evidence, not a current-machine TextKit 2 verification. Existing vertical-only fixture tests cannot establish that priority; a discriminating font is needed next round. No change to the existing vrt2 prediction policy was made during this source-only round.


## Local NSTextView vrt2 discrimination — 2026-10-25

At the user's request, ran one small offscreen NSTextView/TextKit 2 probe on macOS 14.8.7 (23J520). Two original TTFs distinguish default rectangle, vert triangle and vrt2 double bars. Native line-fragment alpha masks match vrt2 when both features exist and vert when only vert exists; horizontal control retains the default. References are encoded output glyphs rendered through the same TextView path, not CoreText reconstruction. Probe/results: .build/vrt2-probe. No product source change or App/ZIP build; the earlier source-only trial still awaits its next-round validation.


## Per-glyph vertical fallback follow-up — 2026-10-26

Added a distinct-glyph control: vrt2 actively substitutes U+3002 but does not cover U+3001; vert covers U+3001. Native offscreen NSTextView/TextKit 2 leaves U+3001 at its default shape when vrt2 exists, whereas the vert-only control substitutes it. This disproves automatic per-glyph vert fallback for this local TTF case. The four curly quotes remain identical to a no-GSUB control in all font variants, so this probe does not justify imposing the upright-punctuation behavior on the app's manual quote compensation. No product code change; retain the existing quote rule. Raw results: .build/vrt2-probe/quote-fallback-results.json.
