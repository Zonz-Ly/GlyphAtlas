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
OUTPUT_APP="$DIST/Glyph Atlas.app"
# Sign and archive away from file-provider metadata that can race xattr removal.
STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/glyph-atlas-build.XXXXXX")"
trap 'rm -rf "$STAGE_ROOT"' EXIT
APP="$STAGE_ROOT/Glyph Atlas.app"
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
    -fobjc-arc -fobjc-arc-exceptions -fmodules \
    -fmodules-cache-path="$MODULE_CACHE" \
    -mmacosx-version-min=12.0 \
    -Oz -flto \
    -Wall -Wextra \
    -Wl,-dead_strip -Wl,-x -Wl,-map,"$ARCH_BIN.map" \
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

echo "→ Assembling $OUTPUT_APP"
rm -rf "$APP"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Resources"
cp "$BUILD/bin/GlyphAtlas" "$BUNDLE/MacOS/GlyphAtlas"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Info.plist"
for LOCALIZATION in "$ROOT"/Resources/*.lproj; do
  cp -R "$LOCALIZATION" "$BUNDLE/Resources/"
done

echo "→ Generating AppIcon.icns"
ICONSET="$STAGE_ROOT/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ROOT/Resources/AppIcon.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  RETINA_SIZE=$((SIZE * 2))
  sips -z "$RETINA_SIZE" "$RETINA_SIZE" "$ROOT/Resources/AppIcon.png" \
    --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Resources/AppIcon.icns"
chmod +x "$BUNDLE/MacOS/GlyphAtlas"

plutil -lint "$BUNDLE/Info.plist" \
  "$BUNDLE"/Resources/*.lproj/*.strings \
  "$BUNDLE"/Resources/*.lproj/*.stringsdict >/dev/null
# The workspace may live on a file-provider volume that attaches Finder
# metadata to folders. Strip it before sealing the bundle.
xattr -cr "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "Code signing failed" >&2
  exit 1
}
xattr -cr "$APP" 2>/dev/null || true
xattr -d com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -d com.apple.fileprovider.fpfs#P "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"

rm -rf "$OUTPUT_APP"
ditto --norsrc --noextattr "$APP" "$OUTPUT_APP"
echo "Done: $OUTPUT_APP"
if "$CREATE_ZIP"; then
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  echo "Archive: $ZIP"
fi
