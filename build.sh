#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
APP="$DIST/Glyph Atlas.app"
ZIP="$DIST/Glyph Atlas.zip"
BUNDLE="$APP/Contents"
ARCHS="${ARCHS:-arm64 x86_64}"

mkdir -p "$BUILD/bin" "$DIST"

ARCH_BINARIES=()
for ARCH in $ARCHS; do
  ARCH_BIN="$BUILD/bin/GlyphAtlas-$ARCH"
  MODULE_CACHE="$BUILD/modulecache-clang-$ARCH"
  mkdir -p "$MODULE_CACHE"
  echo "→ Compiling Glyph Atlas ($ARCH)"
  clang \
    -fobjc-arc -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=12.0 \
    -O2 \
    -Wall -Wextra \
    -arch "$ARCH" \
    -I "$ROOT/Sources" \
    -framework Cocoa \
    -framework CoreText \
    -framework UniformTypeIdentifiers \
    -licucore \
    "$ROOT/Sources"/*.m \
    -o "$ARCH_BIN"
  ARCH_BINARIES+=("$ARCH_BIN")
done

lipo -create "${ARCH_BINARIES[@]}" -output "$BUILD/bin/GlyphAtlas"
echo "→ Architectures: $(lipo -archs "$BUILD/bin/GlyphAtlas")"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"
cp "$BUILD/bin/GlyphAtlas" "$BUNDLE/MacOS/GlyphAtlas"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Info.plist"
chmod +x "$BUNDLE/MacOS/GlyphAtlas"

plutil -lint "$BUNDLE/Info.plist" >/dev/null
# The workspace may live on a file-provider volume that attaches Finder
# metadata to folders. Strip it before sealing the bundle.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "Code signing failed" >&2
  exit 1
}
xattr -cr "$APP" 2>/dev/null || true

rm -f "$ZIP"
if command -v ditto >/dev/null 2>&1; then
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  echo "Done: $APP"
  echo "Archive: $ZIP"
else
  echo "Done: $APP"
fi
