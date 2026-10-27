#!/bin/bash
set -euo pipefail
CORE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$CORE/../.." && pwd)"
ARCH="$1"
OUT="$2"
mkdir -p "$OUT"
FLAGS=(-std=c++17 -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" -I "$CORE")
FLAGS+=(-Oz -flto -ffunction-sections -fdata-sections -fvisibility=hidden -fvisibility-inlines-hidden)
SOURCES=("$CORE"/*.cpp "$CORE"/*.mm)
# Rebuild when compiler flags or the source list change.
printf -v CONFIGURATION '%q ' "${FLAGS[@]}" "${SOURCES[@]}"
CONFIGURATION_FILE="$OUT/.compile-flags"
REBUILD=false
if [[ ! -f "$CONFIGURATION_FILE" || "$(cat "$CONFIGURATION_FILE")" != "$CONFIGURATION" ]]; then
  REBUILD=true
  # Discard objects from removed or renamed translation units.
  rm -f "$OUT"/*.o "$CONFIGURATION_FILE"
fi
for SOURCE in "${SOURCES[@]}"; do
  OBJECT="$OUT/$(basename "${SOURCE%.*}").o"
  if [[ "$REBUILD" == false && -f "$OBJECT" && "$OBJECT" -nt "$SOURCE" && "$OBJECT" -nt "$0" && -z "$(find "$ROOT/Sources" -name '*.h' -newer "$OBJECT" -print -quit)" ]]; then continue; fi
  if [[ "$SOURCE" == *.mm ]]; then
    clang++ "${FLAGS[@]}" -fobjc-arc -c "$SOURCE" -o "$OBJECT"
  else
    clang++ "${FLAGS[@]}" -c "$SOURCE" -o "$OBJECT"
  fi
done
printf '%s' "$CONFIGURATION" > "$CONFIGURATION_FILE"
