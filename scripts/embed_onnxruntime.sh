#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/DeskScribeONNX.app" >&2
  exit 2
fi

APP_PATH="$1"
BREW_PREFIX="${ONNXRUNTIME_PREFIX:-/opt/homebrew/opt/onnxruntime}"
SOURCE_DYLIB="$BREW_PREFIX/lib/libonnxruntime.1.dylib"
FRAMEWORKS_DIR="$APP_PATH/Contents/Frameworks"
BUNDLED_DYLIB="$FRAMEWORKS_DIR/libonnxruntime.1.dylib"
BREW_LINK_PATH="$BREW_PREFIX/lib/libonnxruntime.1.dylib"

if [[ ! -d "$APP_PATH/Contents/MacOS" ]]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$SOURCE_DYLIB" ]]; then
  echo "Missing ONNX Runtime dylib at $SOURCE_DYLIB" >&2
  echo "Install Homebrew onnxruntime or set ONNXRUNTIME_PREFIX." >&2
  exit 1
fi

mkdir -p "$FRAMEWORKS_DIR"
cp -L "$SOURCE_DYLIB" "$BUNDLED_DYLIB"
chmod 755 "$BUNDLED_DYLIB"
install_name_tool -id "@rpath/libonnxruntime.1.dylib" "$BUNDLED_DYLIB"

rewrite_links() {
  local binary="$1"
  if ! otool -L "$binary" >/dev/null 2>&1; then
    return
  fi
  if otool -L "$binary" | /usr/bin/grep -q "$BREW_PREFIX/lib/libonnxruntime"; then
    install_name_tool -change "$BREW_LINK_PATH" "@rpath/libonnxruntime.1.dylib" "$binary"
  fi
}

for binary in "$APP_PATH"/Contents/MacOS/* "$APP_PATH"/Contents/Frameworks/*.dylib; do
  [[ -e "$binary" ]] || continue
  rewrite_links "$binary"
done

codesign --force --sign - --timestamp=none "$BUNDLED_DYLIB"
codesign --force --deep --sign - --timestamp=none "$APP_PATH"

echo "Embedded ONNX Runtime: $BUNDLED_DYLIB"
