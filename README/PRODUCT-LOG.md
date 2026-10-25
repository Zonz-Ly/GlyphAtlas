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
