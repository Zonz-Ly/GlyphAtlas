# Localization

Glyph Atlas uses AppKit's normal bundle localization (`NSLocalizedString`) and
follows the user's preferred languages or macOS per-app language setting.
Unsupported languages fall back to English. The app does not change system
language preferences.

| Language | Resource directory |
| --- | --- |
| English | `en.lproj` |
| Traditional Chinese (Taiwan terminology) | `zh-Hant.lproj` |
| Traditional Chinese (Hong Kong terminology) | `zh-HK.lproj` |
| Simplified Chinese | `zh-Hans.lproj` |
| Japanese | `ja.lproj` |
| Korean | `ko.lproj` |
| German | `de.lproj` |
| French | `fr.lproj` |
| Spanish | `es.lproj` |
| Italian | `it.lproj` |
| Portuguese (Brazil) | `pt-BR.lproj` |
| Russian | `ru.lproj` |
| Arabic | `ar.lproj` |

Each directory contains `Localizable.strings`, `Localizable.stringsdict`, and
`InfoPlist.strings`. `build.sh` copies these resources into the app and validates
their property-list syntax. No external localization library is required.

Standard commands were checked against Apple's translations in macOS 14.8.7
(AppKit MenuCommands, Common, Services, SavePanel, TextTouchBar, Undo and Ruler tables,
Foundation Undo, and Preview's zoom commands). These translations are stored in
the project; the app does not read private system string tables at runtime.

## Editing translations

- Keep the same keys in every `Localizable.strings` file. Use the English catalog
  as the complete inventory. Localize full sentences, including punctuation.
- Keep all font-collection count forms in `Localizable.stringsdict`. The filename
  is argument 1 and the unsigned font count is argument 2. Russian and Arabic
  require more plural forms than English.
- Translate the `Font File` document-type name in both string tables.
- Translate `NSHumanReadableCopyright` in every `InfoPlist.strings`. AppKit
  reads this metadata for the standard About panel, along with the app's icon,
  name, and version. The panel does not supply custom credits.
- Keep font names, glyph names, glyph IDs, Unicode standard character names,
  and OpenType/AAT feature tags intact. Display only recorded feature/selector
  sources. Leave missing sources empty; do not invent or localize `actual`.
- Chinese Help paragraphs (`Help.01`–`Help.12`) follow README's 使用 section.
  Taiwan and Hong Kong use that text verbatim (without Markdown formatting);
  Simplified Chinese uses its character conversion. Keep the original Help alert
  layout. Update these paragraphs when the README usage text changes.
- All three Chinese catalogs use `全部字` for `All Glyphs`. Hong Kong uses `靠左`,
  `靠右`, `靠上`, `靠下`, and `兩端` for the alignment menu. Other standard menu
  commands follow their region's macOS wording.
- Arabic Help isolates keyboard shortcuts with Unicode LTR isolates so that the
  shortcut order is preserved in right-to-left text.

## Validation

On macOS, run:

```sh
python3 Tests/check-catalogs.py
bash Tests/check-localizations.sh
bash build.sh
```

The native smoke test loads all 13 languages and checks regional language
matching, English fallback, plural formatting (including filenames containing a
percent sign), Copy's shortcut, and dynamically updated alignment labels in the
actual AppKit context menu. It needs access to a graphical macOS session but
does not open documents or change language preferences. Build artifacts stay in
`.build/` and `dist/`.

The test also checks localized copyright metadata and application-level
commands remaining available without an open font.
The build generates `AppIcon.icns` from `Resources/AppIcon.png` with macOS
`sips` and `iconutil`; the PNG is the icon's source of truth.
