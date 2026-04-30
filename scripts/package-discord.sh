#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
EXPORT_DIR="$BUILD_DIR/discord"
APP_PATH="$DERIVED_DATA/Build/Products/Release/agentrocky.app"
ZIP_PATH="$EXPORT_DIR/agentrocky-discord.zip"

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "xcodebuild is not available. Install full Xcode and select it with:"
  echo "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  exit 1
fi

rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

xcodebuild \
  -project "$ROOT_DIR/agentrocky.xcodeproj" \
  -scheme agentrocky \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app was not found at $APP_PATH"
  exit 1
fi

codesign --force --deep --sign - "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

cat <<EOF
Created:
$ZIP_PATH

Discord note:
After unzipping, open agentrocky.app. If macOS blocks it, Control-click the app, choose Open, then choose Open again.
EOF
