#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/glyphatlas-review-v3.XXXXXX")"
trap 'rm -rf "$OUT"' EXIT
FLAGS=(-std=c++17 -O1 -g -Wall -Wextra)
if [[ "${SANITIZE:-0}" == 1 ]]; then FLAGS+=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
"${CXX:-clang++}" "${FLAGS[@]}" "$HERE/review_checks.cpp" -o "$OUT/checks"
"$OUT/checks"
