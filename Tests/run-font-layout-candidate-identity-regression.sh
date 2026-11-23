#!/bin/bash
set -euo pipefail
TESTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SOURCE_ROOT:-$(cd "$TESTS/.." && pwd)}"
OUT="${1:-$(mktemp -d "${TMPDIR:-/tmp/}glyphatlas-identity.XXXXXX")}"
mkdir -p "$OUT"
bash "$ROOT/Sources/FontLayout/compile-font-layout.sh" "$(uname -m)" "$OUT/layout"
SOURCES=()
for file in "$ROOT"/Sources/{App,Font,Views}/*.m; do
  [[ "$file" == */main.m ]] || SOURCES+=("$file")
done
clang -fobjc-arc -O2 -Wall -Wextra -I "$ROOT/Sources" "$TESTS/FontLayoutCandidateIdentityRegression.m" \
  "${SOURCES[@]}" "$OUT/layout/"*.o -framework Foundation -framework CoreText -framework AppKit -framework UniformTypeIdentifiers \
  -licucore -lc++ -o "$OUT/candidate-identity-regression"
"$OUT/candidate-identity-regression" > "$OUT/results.txt"
echo "Candidate identity assertions passed: $OUT/results.txt"
