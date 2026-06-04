#!/usr/bin/env bash
set -euo pipefail

BUILD_ROOT="${BUILD_ROOT:-/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-onnx-release-build}"
SOURCE_APP="$BUILD_ROOT/Build/Products/Release/DeskScribeONNX.app"
TARGET_APP="/Applications/DeskScribe ONNX.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing $SOURCE_APP. Run scripts/build_onnx_release.sh first." >&2
  exit 1
fi

if pgrep -x DeskScribeONNX >/dev/null; then
  echo "DeskScribe ONNX is running. Quit it before installing over $TARGET_APP." >&2
  exit 1
fi

rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$TARGET_APP"

echo "Installed $TARGET_APP"
echo "Open System Settings > Privacy & Security > Accessibility and add/enable DeskScribe ONNX."
