#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="NCM批量转MP3"
APP_PATH="$DIST_DIR/$APP_NAME.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/NCMConverter"
RESOURCES="$APP_PATH/Contents/Resources"
FFMPEG_SHA256="9a08d61f9328e8164ba560ee7a79958e357307fcfeea6fe626b7d66cdc287028"
FFMPEG_URL="https://www.osxexperts.net/ffmpeg81arm.zip"

mkdir -p "$BUILD_DIR/ModuleCache" "$BUILD_DIR/SwiftModuleCache" "$DIST_DIR"

echo "Building SwiftUI app..."
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$BUILD_DIR/SwiftModuleCache" \
MACOSX_DEPLOYMENT_TARGET=13.0 \
swiftc \
  -target arm64-apple-macosx13.0 \
  -parse-as-library \
  -O \
  -o "$BUILD_DIR/NCMConverter" \
  "$ROOT_DIR/Sources/NCMBatchMP3App.swift" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Combine \
  -framework UniformTypeIdentifiers

echo "Preparing app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$RESOURCES"
cp "$BUILD_DIR/NCMConverter" "$EXECUTABLE"
cp "$ROOT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
chmod +x "$EXECUTABLE"

echo "Generating icon..."
CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache" \
SWIFT_MODULE_CACHE_PATH="$BUILD_DIR/SwiftModuleCache" \
MACOSX_DEPLOYMENT_TARGET=13.0 \
swiftc \
  -target arm64-apple-macosx13.0 \
  -o "$BUILD_DIR/make_icon" \
  "$ROOT_DIR/scripts/make_icon.swift" \
  -framework AppKit
"$BUILD_DIR/make_icon" "$BUILD_DIR/AppIcon.iconset"
python3 "$ROOT_DIR/scripts/make_icns.py" "$BUILD_DIR/AppIcon.iconset" "$RESOURCES/AppIcon.icns"

echo "Preparing ffmpeg..."
if [[ -x "$ROOT_DIR/Resources/ffmpeg" ]]; then
  cp "$ROOT_DIR/Resources/ffmpeg" "$RESOURCES/ffmpeg"
else
  curl -L "$FFMPEG_URL" -o "$BUILD_DIR/ffmpeg81arm.zip"
  rm -rf "$BUILD_DIR/ffmpeg81arm"
  unzip -q "$BUILD_DIR/ffmpeg81arm.zip" -d "$BUILD_DIR/ffmpeg81arm"
  ACTUAL_SHA="$(shasum -a 256 "$BUILD_DIR/ffmpeg81arm/ffmpeg" | awk '{print $1}')"
  if [[ "$ACTUAL_SHA" != "$FFMPEG_SHA256" ]]; then
    echo "ffmpeg checksum mismatch: $ACTUAL_SHA" >&2
    exit 1
  fi
  cp "$BUILD_DIR/ffmpeg81arm/ffmpeg" "$RESOURCES/ffmpeg"
fi
chmod +x "$RESOURCES/ffmpeg"

cp "$ROOT_DIR/Resources/FFMPEG_NOTICE.txt" "$RESOURCES/FFMPEG_NOTICE.txt"
cp "$ROOT_DIR/README.md" "$RESOURCES/README.md"

echo "Signing..."
xattr -cr "$APP_PATH"
codesign --force --sign - "$RESOURCES/ffmpeg"
codesign --force --deep --sign - "$APP_PATH"

echo "Packaging..."
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$DIST_DIR/NCM批量转MP3-SwiftUI.app.zip"

echo "Done: $DIST_DIR/NCM批量转MP3-SwiftUI.app.zip"
