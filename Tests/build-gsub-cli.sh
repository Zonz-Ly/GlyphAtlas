#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
LAYOUT="$ROOT/.build/font-layout-$ARCH"
bash "$ROOT/scripts/compile-font-layout.sh" "$ARCH" "$LAYOUT"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBCLI.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextScanModel.m" \
  "$LAYOUT"/*.o -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-cli"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBModelTests.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextScanModel.m" \
  "$LAYOUT"/*.o -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-model-tests"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/SeedDisplayTests.m" "$ROOT/Sources/GASeedDisplay.m" \
  -framework Cocoa -framework CoreText -o "$ROOT/.build/seed-display-tests"

CORE=()
for SOURCE in "$ROOT"/Sources/FontLayout/*.cpp; do CORE+=("$LAYOUT/$(basename "${SOURCE%.cpp}").o"); done
clang++ -std=c++17 -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/FontLayoutTests.cpp" "${CORE[@]}" -framework Cocoa -framework CoreText -licucore \
  -o "$ROOT/.build/font-layout-tests"
