#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
LAYOUT="$ROOT/.build/font-layout-test-$ARCH"
bash "$ROOT/scripts/compile-font-layout.sh" "$ARCH" "$LAYOUT" test
clang -DGA_FONT_LAYOUT_TESTING=1 -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBCLI.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextQueryModel.m" \
  "$LAYOUT"/*.o -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-cli"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBModelTests.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextQueryModel.m" \
  "$LAYOUT"/*.o -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-model-tests"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/SeedDisplayTests.m" "$ROOT/Sources/GATextDisplay.m" \
  -framework Cocoa -framework CoreText -o "$ROOT/.build/seed-display-tests"

CORE=("$LAYOUT"/*.o)
clang -fobjc-arc -fobjc-arc-exceptions -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/FontLayoutTests.m" "$ROOT/Sources/GAGlyphSelection.m" "${CORE[@]}" -framework Cocoa -framework CoreText -licucore \
  -o "$ROOT/.build/font-layout-tests"

clang -fobjc-arc -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/TextDisplayTests.m" "$ROOT/Sources/GATextDisplay.m" \
  -framework Cocoa -framework CoreText -o "$ROOT/.build/text-display-tests"
UI_SOURCES=()
for SOURCE in "$ROOT"/Sources/*.m; do
  if [[ "$SOURCE" != "$ROOT/Sources/main.m" && ! -f "$LAYOUT/$(basename "${SOURCE%.m}").o" ]]; then UI_SOURCES+=("$SOURCE"); fi
done
clang -fobjc-arc -flto -Wl,-dead_strip -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/SidebarStateTests.m" "${UI_SOURCES[@]}" "$LAYOUT"/*.o \
  -framework Cocoa -framework CoreText -framework UniformTypeIdentifiers -licucore \
  -o "$ROOT/.build/sidebar-state-tests"

clang -fobjc-arc -flto -Wl,-dead_strip -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/NativeHitTests.m" "$ROOT/Tests/ReferenceNativeTextHit.m" \
  "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextQueryModel.m" \
  "$ROOT/Sources/GATextHitMap.m" "$ROOT/Sources/GATextDisplay.m" "$LAYOUT"/*.o \
  -framework Cocoa -framework CoreText -framework UniformTypeIdentifiers -licucore \
  -o "$ROOT/.build/native-hit-tests"
