#!/bin/bash
set -euo pipefail

CREATE_ZIP=false
ARCHS=""
usage() {
  echo "Usage: bash build.sh [-a | -x | -u] [-z]"
  echo "  Default  Build the current machine's architecture"
  echo "  -a       Build arm64"
  echo "  -x       Build x86_64"
  echo "  -u       Build universal (arm64 + x86_64)"
  echo "  -z       Also create dist/Glyph Atlas.zip with a Clear Attributes.command script"
}

for ARG in "$@"; do
  case "$ARG" in
    -a|-x|-u)
      if [[ -n "$ARCHS" ]]; then
        echo "Choose only one of -a, -x, or -u." >&2
        exit 1
      fi
      case "$ARG" in
        -a) ARCHS="arm64" ;;
        -x) ARCHS="x86_64" ;;
        -u) ARCHS="arm64 x86_64" ;;
      esac
      ;;
    -z|--zip) CREATE_ZIP=true ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $ARG" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ARCHS" ]]; then ARCHS="$(uname -m)"; fi
case "$ARCHS" in
  arm64|x86_64|"arm64 x86_64") ;;
  *) echo "Unsupported architecture: $ARCHS" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/.build"
DIST="$ROOT/dist"
APP="$DIST/Glyph Atlas.app"
ZIP="$DIST/Glyph Atlas.zip"
BUNDLE="$APP/Contents"

mkdir -p "$BUILD/bin" "$DIST"

ARCH_BINARIES=()
APP_SOURCES=("$ROOT"/Sources/{App,Font,Input,Views}/*.m)
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
    "${APP_SOURCES[@]}" "$LAYOUT"/*.o -lc++ \
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
cp "$ROOT/Resources/OpenTypeLanguages.plist" "$BUNDLE/Resources/"
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
  COMMAND="$DIST/Clear Attributes.command"
  rm -f "$COMMAND"
  cat > "$COMMAND" <<'SCRIPT'
#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
/usr/bin/xattr -rc "$SCRIPT_DIR/Glyph Atlas.app"
echo "Extended attributes cleared. You can now open Glyph Atlas.app."
SCRIPT
  chmod +x "$COMMAND"
  PACKAGE="$BUILD/package"
  rm -rf "$PACKAGE"
  mkdir -p "$PACKAGE"
  ditto --norsrc --noextattr "$APP" "$PACKAGE/Glyph Atlas.app"
  cp "$COMMAND" "$PACKAGE/"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr "$PACKAGE" "$ZIP"
  echo "Archive: $ZIP"
fi
