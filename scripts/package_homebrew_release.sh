#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-onnx-release-build}"
RELEASE_APP="$BUILD_ROOT/Build/Products/Release/DeskScribeONNX.app"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
VERSION="${VERSION:-}"
BUILD_RELEASE="${BUILD_RELEASE:-1}"
APP_NAME="${APP_NAME:-DeskScribe ONNX.app}"

if [[ -z "$VERSION" ]]; then
  tag="$(git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
  if [[ -n "$tag" ]]; then
    VERSION="${tag#v}"
  else
    VERSION="0.1.0"
  fi
fi

ZIP_NAME="DeskScribe-${VERSION}-macos.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="$ZIP_PATH.sha256"
STAGING_DIR="$DIST_DIR/homebrew-staging"
STAGED_APP="$STAGING_DIR/$APP_NAME"

if [[ "$BUILD_RELEASE" != "0" ]]; then
  BUILD_VERSION="$VERSION" "$ROOT_DIR/scripts/build_onnx_release.sh"
fi

if [[ ! -d "$RELEASE_APP" ]]; then
  echo "Missing $RELEASE_APP. Run scripts/build_onnx_release.sh first or keep BUILD_RELEASE=1." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR" "$ZIP_PATH" "$SHA_PATH"
mkdir -p "$STAGING_DIR"
ditto "$RELEASE_APP" "$STAGED_APP"

(
  cd "$STAGING_DIR"
  ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_PATH"
)

shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"
rm -rf "$STAGING_DIR"

echo "Packaged Homebrew release ZIP: $ZIP_PATH"
echo "SHA256: $(cut -d ' ' -f 1 "$SHA_PATH")"
