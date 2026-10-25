#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$1"
OUT="$2"
mkdir -p "$OUT"
FLAGS=(-std=c++17 -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources")
if [[ "${SANITIZE:-0}" == 1 ]]; then
  FLAGS+=(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -O1 -gline-tables-only)
else
  FLAGS+=(-Oz -flto -ffunction-sections -fdata-sections -fvisibility=hidden -fvisibility-inlines-hidden)
fi
for SOURCE in "$ROOT"/Sources/FontLayout/*.cpp "$ROOT"/Sources/FontLayout/*.mm "$ROOT/Sources/GASubstitutionEngine.mm"; do
  OBJECT="$OUT/$(basename "${SOURCE%.*}").o"
  if [[ -f "$OBJECT" && "$OBJECT" -nt "$SOURCE" && "$OBJECT" -nt "$0" && -z "$(find "$ROOT/Sources/FontLayout" "$ROOT/Sources/GASubstitutionEngine.h" "$ROOT/Sources/GAGlyphSelection.h" -name '*.h' -newer "$OBJECT" -print -quit)" ]]; then continue; fi
  if [[ "$SOURCE" == *.mm ]]; then
    clang++ "${FLAGS[@]}" -fobjc-arc -c "$SOURCE" -o "$OBJECT"
  else
    clang++ "${FLAGS[@]}" -c "$SOURCE" -o "$OBJECT"
  fi
done
