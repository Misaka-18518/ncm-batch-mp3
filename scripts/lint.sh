#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_SOURCES="$ROOT_DIR/apps/macos/Sources"

# swiftlint needs sourcekitdInProc. On machines without full Xcode, the
# Command Line Tools copy is not on the default dyld search path.
if [[ -z "${DYLD_FRAMEWORK_PATH:-}" ]] &&
    [[ ! -d "/Applications/Xcode.app" ]] &&
    [[ -d "/Library/Developer/CommandLineTools/usr/lib" ]]; then
    export DYLD_FRAMEWORK_PATH="/Library/Developer/CommandLineTools/usr/lib"
fi

echo "Linting Swift sources with swift-format..."
xcrun swift-format lint --strict "$SWIFT_SOURCES"/*.swift

if command -v swiftlint >/dev/null 2>&1; then
    echo "Linting Swift sources with swiftlint..."
    swiftlint lint "$SWIFT_SOURCES"
else
    echo "warning: swiftlint not installed, skipping (brew install swiftlint)" >&2
fi

echo "Lint OK"
