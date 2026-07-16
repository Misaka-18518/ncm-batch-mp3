#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -x "$ROOT_DIR/dist/NCM批量转MP3.app/Contents/MacOS/NCMConverter" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
fi

python3 -m py_compile "$ROOT_DIR/tests/synthetic_ncm_test.py" "$ROOT_DIR/tests/ffmpeg_integration_test.py"
"$ROOT_DIR/dist/NCM批量转MP3.app/Contents/MacOS/NCMConverter" --self-test
python3 "$ROOT_DIR/tests/synthetic_ncm_test.py"
python3 "$ROOT_DIR/tests/ffmpeg_integration_test.py"

DOTNET_BIN="${DOTNET_BIN:-$ROOT_DIR/.build/dotnet/dotnet}"
if [[ ! -x "$DOTNET_BIN" ]]; then
  DOTNET_BIN="$(command -v dotnet || true)"
fi
if [[ -n "$DOTNET_BIN" ]]; then
  DOTNET_CLI_HOME="$ROOT_DIR/.build/dotnet-home" \
  NUGET_PACKAGES="$ROOT_DIR/.build/nuget" \
  DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
  "$DOTNET_BIN" run \
    --project "$ROOT_DIR/windows/NcmBatchMp3.Tests/NcmBatchMp3.Tests.csproj" \
    --configuration Release \
    --nologo
fi
