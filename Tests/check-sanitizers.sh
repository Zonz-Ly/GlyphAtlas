#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
HB="$ROOT/.build/harfbuzz-sanitized.o"
SANITIZERS=(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -O1 -gline-tables-only)
if [[ ! -f "$HB" || "$ROOT/scripts/compile-harfbuzz.sh" -nt "$HB" ]]; then
  clang++ -std=c++17 "${SANITIZERS[@]}" -mmacosx-version-min=12.0 -arch "$ARCH" \
    -DHB_BUFFER_MESSAGE_MORE=1 -DHB_NO_CORETEXT -DHB_NO_GRAPHITE2 -DHB_NO_FREETYPE \
    -I "$ROOT/Vendor/harfbuzz/src" -c "$ROOT/Vendor/harfbuzz/src/harfbuzz.cc" -o "$HB"
fi
clang -fobjc-arc "${SANITIZERS[@]}" -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBCLI.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GASubstitutionEngine.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextScanModel.m" \
  "$HB" -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-cli-sanitized"
ASAN_OPTIONS=detect_leaks=0 python3 - "$ROOT" <<'PY'
import json,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);cli=root/'.build/gsub-cli-sanitized';fixtures=root/'Tests/Fixtures'
fonts=sorted(list(fixtures.glob('*.ttf'))+list(fixtures.glob('*.ttc')))
for path in fonts:
    p=subprocess.run([str(cli),'--font',str(path),'--text','xaby f́fi ab 😀','--model'],capture_output=True,text=True,timeout=10)
    assert p.returncode==0,(path.name,p.stderr,p.stdout)
    assert not p.stderr,(path.name,p.stderr)
    json.loads(p.stdout)
for font in ['morx4.ttf','mort1.ttf']:
    subprocess.run([str(cli),'--font',str(fixtures/font),'--text','ab','--shape','--feature','liga=0'],check=True,capture_output=True)
print('OK: AddressSanitizer + UndefinedBehaviorSanitizer;',len(fonts),'fonts; no GUI')
PY
