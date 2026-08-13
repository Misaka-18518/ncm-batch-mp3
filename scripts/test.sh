#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -x "$ROOT_DIR/dist/NCM批量转MP3.app/Contents/MacOS/NCMConverter" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

python3 -m py_compile "$ROOT_DIR/tests/macos/synthetic_ncm_test.py" "$ROOT_DIR/tests/macos/ffmpeg_integration_test.py"
"$ROOT_DIR/scripts/lint.sh"
"$ROOT_DIR/dist/NCM批量转MP3.app/Contents/MacOS/NCMConverter" --self-test
python3 "$ROOT_DIR/tests/macos/synthetic_ncm_test.py"
if [[ -x "$ROOT_DIR/dist/NCM批量转MP3.app/Contents/Resources/ffmpeg" ]]; then
  python3 "$ROOT_DIR/tests/macos/ffmpeg_integration_test.py"
else
  echo "跳过 ffmpeg 集成测试（未下载内置 ffmpeg，先运行 scripts/build_app.sh）"
fi

DOTNET_BIN="${DOTNET_BIN:-$ROOT_DIR/.build/dotnet/dotnet}"
if [[ ! -x "$DOTNET_BIN" ]]; then
  DOTNET_BIN="$(command -v dotnet || true)"
fi
if [[ -n "$DOTNET_BIN" ]]; then
  DOTNET_CLI_HOME="$ROOT_DIR/.build/dotnet-home" \
  NUGET_PACKAGES="$ROOT_DIR/.build/nuget" \
  DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
  "$DOTNET_BIN" run \
    --project "$ROOT_DIR/apps/windows/NcmBatchMp3.Tests/NcmBatchMp3.Tests.csproj" \
    --configuration Release \
    --nologo
fi
