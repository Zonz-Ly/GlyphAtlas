#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
: "${SOURCE_ROOT:?Set SOURCE_ROOT to a local GlyphAtlas repository checkout}"
CORE="$SOURCE_ROOT/Sources/FontLayout"
[[ -f "$CORE/GAOpenType.cpp" ]] || { echo "Invalid SOURCE_ROOT" >&2; exit 2; }
OUT="$(mktemp -d "${TMPDIR:-/tmp}/glyphatlas-mark-checks.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-std=c++17 -O1 -g -Wall -Wextra)
if [[ "${SANITIZE:-0}" == 1 ]]; then FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CXX:-clang++}" "${FLAGS[@]}" -I "$CORE" "$HERE/production_mark_regression.cpp" \
  "$CORE/GAOpenType.cpp" "$CORE/GASubstitution.cpp" "$CORE/GAGlyphBuffer.cpp" \
  "$CORE/GAGlyphCatalogue.cpp" "$CORE/GAPositioning.cpp" \
  "$CORE/GAVariation.cpp" "$CORE/GAAAT.cpp" -o "$OUT/checks"
"$OUT/checks"
