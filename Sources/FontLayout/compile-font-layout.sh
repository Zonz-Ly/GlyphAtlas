#!/bin/bash
set -euo pipefail
CORE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CORE/../.." && pwd)"
ARCH="$1"
OUT="$2"
MODE="${3:-release}"
mkdir -p "$OUT"
FLAGS=(-std=c++17 -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" -I "$CORE")
case "$MODE" in
  release) FLAGS+=(-DGA_FONT_LAYOUT_TESTING=0) ;;
  test) FLAGS+=(-DGA_FONT_LAYOUT_TESTING=1) ;;
  *) echo "Unknown font-layout build mode: $MODE" >&2; exit 1 ;;
esac
if [[ "${SANITIZE:-0}" == 1 ]]; then
  FLAGS+=(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -O1 -gline-tables-only)
else
  FLAGS+=(-Oz -flto -ffunction-sections -fdata-sections -fvisibility=hidden -fvisibility-inlines-hidden)
fi
# A directory reused with another mode must never supply stale test-enabled
# objects to a release link (or stale optimized objects to sanitizer tests).
printf -v CONFIGURATION '%q ' "${FLAGS[@]}"
CONFIGURATION_FILE="$OUT/.compile-flags"
REBUILD=false
if [[ ! -f "$CONFIGURATION_FILE" || "$(cat "$CONFIGURATION_FILE")" != "$CONFIGURATION" ]]; then
  REBUILD=true
  # Switching between saved language implementations can also change the
  # translation-unit list. Never link obsolete objects from the other version.
  rm -f "$OUT"/*.o "$CONFIGURATION_FILE"
fi
for SOURCE in "$CORE"/*.cpp "$CORE"/*.mm; do
  OBJECT="$OUT/$(basename "${SOURCE%.*}").o"
  if [[ "$REBUILD" == false && -f "$OBJECT" && "$OBJECT" -nt "$SOURCE" && "$OBJECT" -nt "$0" && -z "$(find "$ROOT/Sources" -name '*.h' -newer "$OBJECT" -print -quit)" ]]; then continue; fi
  if [[ "$SOURCE" == *.mm ]]; then
    clang++ "${FLAGS[@]}" -fobjc-arc -c "$SOURCE" -o "$OBJECT"
  else
    clang++ "${FLAGS[@]}" -c "$SOURCE" -o "$OBJECT"
  fi
done
printf '%s' "$CONFIGURATION" > "$CONFIGURATION_FILE"
