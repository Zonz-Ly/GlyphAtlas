#!/bin/bash
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd "$TESTS/.." && pwd)}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp/}glyphatlas-components.XXXXXX")}"
mkdir -p "$OUT"
bash "$ROOT/Sources/FontLayout/compile-font-layout.sh" "$(uname -m)" "$OUT/layout"
clang -fobjc-arc -O2 -Wall -Wextra -I "$ROOT/Sources" \
  "$TESTS/FontLayoutMarkComponentRegression.m" "$ROOT/Sources/Font/GAFontEngine.m" \
  "$ROOT/Sources/Font/GATextQueryModel.m" "$ROOT/Sources/Font/GAUnicode.m" \
  "$ROOT/Sources/Font/GAGlyphSelection.m" "$OUT/layout/"*.o \
  -framework Foundation -framework CoreText -framework AppKit -licucore -lc++ \
  -o "$OUT/mark-component-regression"
"$OUT/mark-component-regression" "$TESTS/Fixtures" > "$OUT/results.txt"
echo "Mark component assertions passed: $OUT/results.txt"
