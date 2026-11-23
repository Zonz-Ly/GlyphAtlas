#!/bin/bash
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd "$TESTS/.." && pwd)}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp/}glyphatlas-engine-tests.XXXXXX")}"
mkdir -p "$OUT"
bash "$ROOT/Sources/FontLayout/compile-font-layout.sh" "$(uname -m)" "$OUT/layout"
clang -fobjc-arc -Wall -Wextra -O2 -I "$ROOT/Sources" \
  "$TESTS/FontLayoutEngineRegression.m" "$ROOT/Sources/Font/GAGlyphSelection.m" \
  "$OUT/layout/"*.o -framework Foundation -framework CoreText -licucore -lc++ \
  -o "$OUT/font-layout-engine-regression"
"$OUT/font-layout-engine-regression" > "$OUT/results.json"
echo "Native font-engine regression passed: $OUT/results.json"
