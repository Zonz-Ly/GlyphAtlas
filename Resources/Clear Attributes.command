#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
/usr/bin/xattr -rc "$SCRIPT_DIR/Glyph Atlas.app"
echo "Extended attributes cleared. You can now open Glyph Atlas.app."
