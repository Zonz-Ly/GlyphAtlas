#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="${ARCH:-$(uname -m)}"
HB="$ROOT/.build/harfbuzz-$ARCH.o"
bash "$ROOT/scripts/compile-harfbuzz.sh" "$ARCH" "$HB"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBCLI.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GASubstitutionEngine.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextScanModel.m" \
  "$HB" -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-cli"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBModelTests.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GASubstitutionEngine.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextScanModel.m" \
  "$HB" -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-model-tests"
clang -fobjc-arc -flto -Wl,-dead_strip -Wl,-x -Oz -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/SeedDisplayTests.m" "$ROOT/Sources/GASeedDisplay.m" \
  -framework Cocoa -framework CoreText -o "$ROOT/.build/seed-display-tests"
