#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_SOURCES="$ROOT_DIR/apps/macos/Sources"
CSHARP_PROJECTS=(
    "$ROOT_DIR/apps/windows/NcmBatchMp3.Core/NcmBatchMp3.Core.csproj"
    "$ROOT_DIR/apps/windows/NcmBatchMp3.App/NcmBatchMp3.App.csproj"
    "$ROOT_DIR/apps/windows/NcmBatchMp3.Tests/NcmBatchMp3.Tests.csproj"
)

DOTNET_BIN="${DOTNET_BIN:-$ROOT_DIR/.build/dotnet/dotnet}"
if [[ ! -x "$DOTNET_BIN" ]]; then
    DOTNET_BIN="$(command -v dotnet || true)"
fi

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

if [[ -n "$DOTNET_BIN" ]]; then
    echo "Linting C# projects with dotnet format and analyzers..."
    export DOTNET_CLI_HOME="${DOTNET_CLI_HOME:-$ROOT_DIR/.build/dotnet-home}"
    export NUGET_PACKAGES="${NUGET_PACKAGES:-$ROOT_DIR/.build/nuget}"
    export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
    for project in "${CSHARP_PROJECTS[@]}"; do
        "$DOTNET_BIN" format "$project" --no-restore --verify-no-changes
        "$DOTNET_BIN" build "$project" -c Release --nologo -warnaserror >/dev/null
    done
else
    echo "warning: .NET SDK not found, skipping C# lint (install via dotnet-install.sh)" >&2
fi

echo "Lint OK"
