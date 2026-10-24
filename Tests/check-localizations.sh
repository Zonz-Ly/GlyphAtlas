#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/LocalizationSmoke.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.zonz.GlyphAtlas.LocalizationSmoke' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :LSUIElement bool true' "$APP/Contents/Info.plist"
for LOCALIZATION in "$ROOT"/Resources/*.lproj; do
  cp -R "$LOCALIZATION" "$APP/Contents/Resources/"
done
# Keep the production bundle's executable name so NSBundle sees a real app.
SOURCES=()
for SOURCE in "$ROOT"/Sources/*.m; do
  [[ "$(basename "$SOURCE")" == main.m ]] || SOURCES+=("$SOURCE")
done
HB="$ROOT/.build/harfbuzz-$(uname -m).o"
bash "$ROOT/scripts/compile-harfbuzz.sh" "$(uname -m)" "$HB"
clang -fobjc-arc -flto -Wl,-dead_strip -mmacosx-version-min=12.0 -Wall -Wextra \
  -I "$ROOT/Sources" -framework Cocoa -framework CoreText \
  -framework UniformTypeIdentifiers -licucore \
  "${SOURCES[@]}" "$ROOT/Tests/LocalizationSmoke.m" "$HB" -lc++ \
  -o "$APP/Contents/MacOS/GlyphAtlas"
for LOCALE in en zh-Hant zh-HK zh-Hans ja ko de fr es it pt-BR ru ar; do
  "$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages "($LOCALE)" -expectedLocale "$LOCALE"
done
# Check region/language matching, not just exact resource-folder names.
"$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages '(zh-TW)' -expectedLocale zh-Hant
"$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages '(zh-Hant-HK)' -expectedLocale zh-HK
"$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages '(zh-CN)' -expectedLocale zh-Hans
"$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages '(pt-BR)' -expectedLocale pt-BR
"$APP/Contents/MacOS/GlyphAtlas" -AppleLanguages '(zz)' -expectedLocale en
