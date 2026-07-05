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
