#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WINDOWS_DIR="$ROOT_DIR/windows"
WIN_FFMPEG="$WINDOWS_DIR/resources/win/ffmpeg.exe"

NODE_BIN="${NODE_BIN:-}"
PNPM_BIN="${PNPM_BIN:-}"
PYTHON_BIN="${PYTHON_BIN:-}"

if [[ -z "$NODE_BIN" ]]; then
  NODE_BIN="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node"
fi
if [[ ! -x "$NODE_BIN" ]]; then
  NODE_BIN="$(command -v node || true)"
fi
if [[ -z "$PNPM_BIN" ]]; then
  PNPM_BIN="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/bin/fallback/pnpm"
fi
if [[ ! -x "$PNPM_BIN" ]]; then
  PNPM_BIN="$(command -v pnpm || true)"
fi
if [[ -z "$PYTHON_BIN" ]]; then
  PYTHON_BIN="$HOME/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3"
fi
if [[ ! -x "$PYTHON_BIN" ]]; then
  PYTHON_BIN="$(command -v python3 || true)"
fi

if [[ -z "$NODE_BIN" || -z "$PNPM_BIN" || -z "$PYTHON_BIN" ]]; then
  echo "Missing Node.js, pnpm, or Python runtime" >&2
  exit 1
fi

export PATH="$(dirname "$NODE_BIN"):$(dirname "$PNPM_BIN"):$PATH"
export CI=true
export PNPM_CONFIG_CONFIRM_MODULES_PURGE=false
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_BUILDER_BINARIES_MIRROR="${ELECTRON_BUILDER_BINARIES_MIRROR:-https://npmmirror.com/mirrors/electron-builder-binaries/}"

echo "Generating Windows icon..."
"$PYTHON_BIN" "$WINDOWS_DIR/scripts/make_icon.py"

echo "Installing Windows app dependencies..."
cd "$WINDOWS_DIR"
if [[ -f pnpm-lock.yaml ]]; then
  "$PNPM_BIN" install --frozen-lockfile
else
  "$PNPM_BIN" install
fi

echo "Preparing Windows ffmpeg..."
if [[ ! -f "$WIN_FFMPEG" ]]; then
  mkdir -p "$WINDOWS_DIR/resources/win"
  PACKAGE_FFMPEG="$WINDOWS_DIR/node_modules/@ffmpeg-installer/win32-x64/ffmpeg.exe"
  if [[ ! -f "$PACKAGE_FFMPEG" ]]; then
    echo "ffmpeg.exe not found in @ffmpeg-installer/win32-x64" >&2
    exit 1
  fi
  cp "$PACKAGE_FFMPEG" "$WIN_FFMPEG"
fi

echo "Running Windows core tests..."
"$PNPM_BIN" run test:core

echo "Building Windows installer..."
"$PNPM_BIN" run dist:win

echo "Done: $ROOT_DIR/dist/windows"
