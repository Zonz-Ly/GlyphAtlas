#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OLD_ROOT="${OLD_ROOT:-$ROOT/../Glyph Atlas Old}"
clang -fobjc-arc -O2 -Wall -Wextra -mmacosx-version-min=12.0 -I "$OLD_ROOT/Sources" \
  "$ROOT/Tests/LegacyScanCLI.m" "$OLD_ROOT/Sources/GAFontEngine.m" \
  "$OLD_ROOT/Sources/GAFontResource.m" "$OLD_ROOT/Sources/GAUnicode.m" \
  "$OLD_ROOT/Sources/GATextScanModel.m" -framework Cocoa -framework CoreText -licucore \
  -o "$ROOT/.build/legacy-scan-cli"
python3 "$ROOT/Tests/compare-old.py"
