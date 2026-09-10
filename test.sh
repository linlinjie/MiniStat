#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="$PROJECT_DIR/.build/direct-tests"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

/bin/mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

"$SWIFTC" \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    "$PROJECT_DIR/Sources/MiniStat/MetricModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/MetricFormatter.swift" \
    "$PROJECT_DIR/Sources/MiniStat/ProcessTrafficModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/SettingsStore.swift" \
    "$PROJECT_DIR/Sources/MiniStat/QuotaModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/BoundedCommand.swift" \
    "$PROJECT_DIR/Sources/MiniStat/ScreenshotModels.swift" \
    "$PROJECT_DIR/Tests/CommandLineTests/main.swift" \
    -o "$BUILD_DIR/MiniStatTests"

"$BUILD_DIR/MiniStatTests"

"$SWIFTC" -module-cache-path "$MODULE_CACHE" -sdk "$SDK_PATH" -target arm64-apple-macosx13.0 \
    "$PROJECT_DIR/Sources/MiniStat/ScreenshotModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/ScreenshotCanvas.swift" \
    "$PROJECT_DIR/Sources/MiniStat/ScreenshotEditor.swift" \
    "$PROJECT_DIR/Sources/MiniStat/MetricModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/MetricFormatter.swift" \
    "$PROJECT_DIR/Sources/MiniStat/SettingsStore.swift" \
    "$PROJECT_DIR/Sources/MiniStat/QuotaModels.swift" \
    "$PROJECT_DIR/Sources/MiniStat/StatusBarMetricsView.swift" \
    "$PROJECT_DIR/Tests/ScreenshotRendering/Smoke.swift" \
    -o "$BUILD_DIR/ScreenshotRenderingTests" -framework AppKit
"$BUILD_DIR/ScreenshotRenderingTests"
