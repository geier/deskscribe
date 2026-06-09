#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-debug-build}"
PROJECT="$ROOT_DIR/macos/DeskScribe/DeskScribe.xcodeproj"
BUILD_VERSION="${BUILD_VERSION:-$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD 2>/dev/null || printf unknown)}"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -project "$PROJECT" -scheme DeskScribe -configuration Debug -derivedDataPath "$BUILD_ROOT" CURRENT_PROJECT_VERSION="$BUILD_VERSION" build

"$ROOT_DIR/scripts/embed_onnxruntime.sh" "$BUILD_ROOT/Build/Products/Debug/DeskScribe.app"

echo "Build version:    $BUILD_VERSION"
echo "Built debug app:  $BUILD_ROOT/Build/Products/Debug/DeskScribe.app"
