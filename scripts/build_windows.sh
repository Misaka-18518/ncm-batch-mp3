#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WINDOWS_DIR="$ROOT_DIR/windows"
BUILD_DIR="$ROOT_DIR/.build/windows-native"
PUBLISH_DIR="$ROOT_DIR/dist/windows/app"
OUTPUT_FILE="$ROOT_DIR/dist/windows/NCM-Batch-MP3-Setup-1.2.0-x64.exe"
WIN_FFMPEG="$WINDOWS_DIR/resources/win/ffmpeg.exe"
VERSION="1.2.0"

DOTNET_BIN="${DOTNET_BIN:-$ROOT_DIR/.build/dotnet/dotnet}"
if [[ ! -x "$DOTNET_BIN" ]]; then
  DOTNET_BIN="$(command -v dotnet || true)"
fi
if [[ -z "$DOTNET_BIN" ]]; then
  echo "Missing .NET 8 SDK" >&2
  exit 1
fi

export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$ROOT_DIR/.build/dotnet-home}"
export NUGET_PACKAGES="${NUGET_PACKAGES:-$ROOT_DIR/.build/nuget}"
export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
export DOTNET_CLI_TELEMETRY_OPTOUT=1

mkdir -p "$BUILD_DIR" "$PUBLISH_DIR" "$(dirname "$WIN_FFMPEG")"

if [[ ! -f "$WIN_FFMPEG" ]]; then
  echo "Downloading Windows ffmpeg..."
  FFMPEG_ARCHIVE="$BUILD_DIR/win32-x64-4.1.0.tgz"
  FFMPEG_UNPACKED="$BUILD_DIR/ffmpeg-package"
  curl -L "https://registry.npmjs.org/@ffmpeg-installer/win32-x64/-/win32-x64-4.1.0.tgz" -o "$FFMPEG_ARCHIVE"
  rm -rf "$FFMPEG_UNPACKED"
  mkdir -p "$FFMPEG_UNPACKED"
  tar -xzf "$FFMPEG_ARCHIVE" -C "$FFMPEG_UNPACKED"
  cp "$FFMPEG_UNPACKED/package/ffmpeg.exe" "$WIN_FFMPEG"
fi

echo "Running native C# core tests..."
"$DOTNET_BIN" run \
  --project "$WINDOWS_DIR/NcmBatchMp3.Tests/NcmBatchMp3.Tests.csproj" \
  --configuration Release \
  --nologo

echo "Publishing self-contained WPF app..."
rm -rf "$PUBLISH_DIR"
"$DOTNET_BIN" publish \
  "$WINDOWS_DIR/NcmBatchMp3.App/NcmBatchMp3.App.csproj" \
  --configuration Release \
  --runtime win-x64 \
  --self-contained true \
  --output "$PUBLISH_DIR" \
  -p:PublishReadyToRun=true \
  -p:DebugType=None \
  -p:DebugSymbols=false \
  --nologo

MAKENSIS_BIN="${MAKENSIS_BIN:-$(command -v makensis || true)}"
if [[ -z "$MAKENSIS_BIN" && -x "$HOME/Library/Caches/electron-builder/nsis-3.0.4.1/nsis-3.0.4.1-w8az6/mac/makensis" ]]; then
  NSIS_ROOT="$HOME/Library/Caches/electron-builder/nsis-3.0.4.1/nsis-3.0.4.1-w8az6"
  MAKENSIS_BIN="$NSIS_ROOT/mac/makensis"
  export NSISDIR="$NSIS_ROOT"
fi
if [[ -z "$MAKENSIS_BIN" ]]; then
  echo "Missing NSIS makensis" >&2
  exit 1
fi

echo "Building native Windows installer..."
rm -f "$OUTPUT_FILE"
"$MAKENSIS_BIN" \
  -DVERSION="$VERSION" \
  -DPUBLISH_DIR="$PUBLISH_DIR" \
  -DOUTPUT_FILE="$OUTPUT_FILE" \
  -DICON_FILE="$WINDOWS_DIR/assets/icon.ico" \
  "$WINDOWS_DIR/installer/installer.nsi"

echo "Done: $OUTPUT_FILE"
