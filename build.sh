#!/bin/bash
set -euo pipefail

CREATE_ZIP=false
for ARG in "$@"; do
  case "$ARG" in
    --zip) CREATE_ZIP=true ;;
    -h|--help)
      echo "Usage: bash build.sh [--zip]"
      echo "  --zip  Also package the app as dist/Glyph Atlas.zip"
      exit 0
      ;;
    *)
      echo "Unknown argument: $ARG" >&2
      echo "Usage: bash build.sh [--zip]" >&2
      exit 1
      ;;
  esac
done

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
  LAYOUT="$BUILD/font-layout-$ARCH"
  bash "$ROOT/Sources/FontLayout/compile-font-layout.sh" "$ARCH" "$LAYOUT"
  echo "→ Compiling Glyph Atlas ($ARCH)"
  clang \
    -fobjc-arc -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=12.0 \
    -O2 -flto \
    -Wall -Wextra \
    -Wl,-dead_strip -Wl,-x -Wl,-map,"$ARCH_BIN.map" \
    -arch "$ARCH" \
    -I "$ROOT/Sources" \
    -framework Cocoa \
    -framework CoreText \
    -framework UniformTypeIdentifiers \
    -licucore \
    "$ROOT/Sources"/*.m "$LAYOUT"/*.o -lc++ \
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
for LOCALIZATION in "$ROOT"/Resources/*.lproj; do
  cp -R "$LOCALIZATION" "$BUNDLE/Resources/"
done

cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/Assets.car" "$BUNDLE/Resources/"
chmod +x "$BUNDLE/MacOS/GlyphAtlas"

plutil -lint "$BUNDLE/Info.plist" \
  "$BUNDLE"/Resources/*.lproj/*.strings \
  "$BUNDLE"/Resources/*.lproj/*.stringsdict >/dev/null
# The workspace may live on a file-provider volume that attaches Finder
# metadata to folders. Strip it before sealing the bundle.
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "Code signing failed" >&2
  exit 1
}
xattr -cr "$APP" 2>/dev/null || true

echo "Done: $APP"
if "$CREATE_ZIP"; then
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  echo "Archive: $ZIP"
fi
