#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
LAYOUT="$ROOT/.build/font-layout-test-sanitized-$ARCH"
SANITIZERS=(-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -O1 -gline-tables-only)
SANITIZE=1 bash "$ROOT/scripts/compile-font-layout.sh" "$ARCH" "$LAYOUT" test
clang -DGA_FONT_LAYOUT_TESTING=1 -fobjc-arc "${SANITIZERS[@]}" -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/GSUBCLI.m" "$ROOT/Sources/GAFontEngine.m" "$ROOT/Sources/GAGlyphSelection.m" "$ROOT/Sources/GADisplayGroups.m" \
  "$ROOT/Sources/GAFontResource.m" "$ROOT/Sources/GAUnicode.m" "$ROOT/Sources/GATextQueryModel.m" \
  "$LAYOUT"/*.o -lc++ -framework Cocoa -framework CoreText -licucore -o "$ROOT/.build/gsub-cli-sanitized"
CORE=()
for SOURCE in "$ROOT"/Sources/*.cpp; do CORE+=("$LAYOUT/$(basename "${SOURCE%.cpp}").o"); done
clang++ -std=c++17 "${SANITIZERS[@]}" -Wall -Wextra -mmacosx-version-min=12.0 -arch "$ARCH" -I "$ROOT/Sources" \
  "$ROOT/Tests/FontLayoutTests.cpp" "${CORE[@]}" -framework Cocoa -framework CoreText -licucore \
  -o "$ROOT/.build/font-layout-tests-sanitized"
ASAN_OPTIONS=detect_leaks=0 "$ROOT/.build/font-layout-tests-sanitized" "$ROOT/Tests/Fixtures"
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
for name,text in [('unencoded-neighbor.ttf','ab'),('morx-unencoded-neighbor.ttf','ai'),('mort-unencoded-neighbor.ttf','ai')]:
    p=subprocess.run([str(cli),'--font',str(fixtures/name),'--text',text,'--seed','0:1=9,19','--model'],capture_output=True,text=True,timeout=10)
    assert p.returncode==0 and not p.stderr,(name,p.stderr,p.stdout)
    rows=json.loads(p.stdout)['groups']
    assert any(v['glyphs']==[9,22] for row in rows for v in row['variants']),(name,rows)
print('OK: AddressSanitizer + UndefinedBehaviorSanitizer;',len(fonts),'fonts; no GUI')
PY
