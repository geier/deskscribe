#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build_release.sh VERSION

Builds dist/DeskScribe-VERSION-macos.zip for GitHub Releases.

Environment:
  PYTHON_BIN           Python used to create the bundled worker venv. Default: python3
  CODE_SIGN_IDENTITY   Signing identity for the final app. Default: - (ad hoc)
  CODE_SIGN_KEYCHAIN   Optional keychain passed to codesign and xcodebuild.
  SKIP_PIP_INSTALL=1   Create the venv but skip installing requirements, for script testing only.
USAGE
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

VERSION="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_ROOT="$DIST_DIR/build"
APP_NAME="DeskScribe.app"
APP_PATH="$BUILD_ROOT/Build/Products/Release/$APP_NAME"
STAGED_APP="$DIST_DIR/$APP_NAME"
WORKER_DIR="$STAGED_APP/Contents/Resources/Worker"
ZIP_PATH="$DIST_DIR/DeskScribe-$VERSION-macos.zip"
PYTHON_BIN="${PYTHON_BIN:-python3}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SKIP_PIP_INSTALL="${SKIP_PIP_INSTALL:-0}"
BUILD_VERSION="${BUILD_VERSION:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"

XCODEBUILD_ARGS=(
  -project "$ROOT_DIR/macos/ParakeetDictation/ParakeetDictation.xcodeproj"
  -scheme ParakeetDictation
  -configuration Release
  -derivedDataPath "$BUILD_ROOT"
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY"
  MARKETING_VERSION="$VERSION"
  CURRENT_PROJECT_VERSION="$BUILD_VERSION"
  build
)

if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
  XCODEBUILD_ARGS+=(OTHER_CODE_SIGN_FLAGS="--keychain $CODE_SIGN_KEYCHAIN")
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild "${XCODEBUILD_ARGS[@]}"

ditto "$APP_PATH" "$STAGED_APP"

mkdir -p "$WORKER_DIR"
cp "$ROOT_DIR/asr_worker.py" "$WORKER_DIR/asr_worker.py"
cp "$ROOT_DIR/transcribe_mic.py" "$WORKER_DIR/transcribe_mic.py"
cp "$ROOT_DIR/requirements.txt" "$WORKER_DIR/requirements.txt"

"$PYTHON_BIN" -m venv --copies "$WORKER_DIR/.venv"
"$WORKER_DIR/.venv/bin/python" -m pip install --upgrade pip setuptools wheel

if [[ "$SKIP_PIP_INSTALL" != "1" ]]; then
  "$WORKER_DIR/.venv/bin/python" -m pip install -r "$WORKER_DIR/requirements.txt"
fi

CODESIGN_ARGS=(--force --deep --timestamp=none --sign "$CODE_SIGN_IDENTITY")
if [[ -n "${CODE_SIGN_KEYCHAIN:-}" ]]; then
  CODESIGN_ARGS+=(--keychain "$CODE_SIGN_KEYCHAIN")
fi
codesign "${CODESIGN_ARGS[@]}" "$STAGED_APP"

pushd "$DIST_DIR" >/dev/null
ditto -c -k --keepParent "$APP_NAME" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"
popd >/dev/null

echo "Build version: $BUILD_VERSION"
echo "Built $ZIP_PATH"
cat "$ZIP_PATH.sha256"
