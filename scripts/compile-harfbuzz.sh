#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$1"
OUT="$2"
mkdir -p "$(dirname "$OUT")"
if [[ -f "$OUT" ]] && [[ "$OUT" -nt "$0" ]] && [[ -z "$(find "$ROOT/Vendor/harfbuzz/src" -type f -newer "$OUT" -print -quit)" ]]; then exit 0; fi
# Compile HarfBuzz amalgamation as one translation unit. LTO lets the final
# executable discard unused API implementations, not just unused object files.
clang++ -std=c++17 -Oz -flto -ffunction-sections -fdata-sections \
  -fvisibility=hidden -fvisibility-inlines-hidden -mmacosx-version-min=12.0 -arch "$ARCH" \
  -DHB_BUFFER_MESSAGE_MORE=1 -DHB_NO_CORETEXT -DHB_NO_GRAPHITE2 -DHB_NO_FREETYPE \
  -I "$ROOT/Vendor/harfbuzz/src" -c "$ROOT/Vendor/harfbuzz/src/harfbuzz.cc" -o "$OUT"
