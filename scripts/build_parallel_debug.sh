#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${BUILD_ROOT:-/var/folders/3x/dysmy0zs1tzcky924d23y5br0000gn/T/opencode/deskscribe-parallel-build}"
PROJECT="$ROOT_DIR/macos/ParakeetDictation/ParakeetDictation.xcodeproj"

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -project "$PROJECT" -scheme ParakeetDictation -configuration Debug -derivedDataPath "$BUILD_ROOT" build

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  xcodebuild -project "$PROJECT" -scheme DeskScribeONNX -configuration Debug -derivedDataPath "$BUILD_ROOT" build

echo "Built stable app: $BUILD_ROOT/Build/Products/Debug/DeskScribe.app"
echo "Built ONNX app:   $BUILD_ROOT/Build/Products/Debug/DeskScribeONNX.app"
