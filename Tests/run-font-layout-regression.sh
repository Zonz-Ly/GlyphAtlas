#!/bin/bash
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd "$TESTS/.." && pwd)}"
CORE="$ROOT/Sources/FontLayout"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp/}glyphatlas-layout-tests.XXXXXX")}"
mkdir -p "$OUT"
FLAGS=(-std=c++17 -O1 -g -Wall -Wextra)
if [[ "${SANITIZE:-0}" == 1 ]]; then
  FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer)
fi
clang++ "${FLAGS[@]}" -I "$CORE" "$TESTS/FontLayoutRegression.cpp" \
  "$CORE/GAOpenType.cpp" "$CORE/GASubstitution.cpp" "$CORE/GAGlyphBuffer.cpp" \
  "$CORE/GAGlyphCatalogue.cpp" "$CORE/GAPositioning.cpp" \
  "$CORE/GAVariation.cpp" "$CORE/GAAAT.cpp" -o "$OUT/font-layout-regression"
"$OUT/font-layout-regression" > "$OUT/results.txt"
if [[ -n "${2:-}" ]]; then
  cmp "$2" "$OUT/results.txt"
  echo "Font-layout transcript matches: $2"
fi
echo "Font-layout assertions passed; transcript: $OUT/results.txt"
