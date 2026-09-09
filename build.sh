#!/bin/zsh

set -euo pipefail

PROJECT_DIR="${0:A:h}"
WORKSPACE_DIR="${PROJECT_DIR:h}"
OUTPUT_DIR="$WORKSPACE_DIR/outputs"
APP_PATH="$OUTPUT_DIR/MiniStat.app"
ZIP_PATH="$OUTPUT_DIR/MiniStat-0.3.0-arm64.zip"
SOURCE_ZIP_PATH="$OUTPUT_DIR/MiniStat-0.3.0-source.zip"
BUILD_DIR="$PROJECT_DIR/.build/direct-release"
MODULE_CACHE="$PROJECT_DIR/.build/module-cache"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"

cd "$PROJECT_DIR"

/bin/mkdir -p "$BUILD_DIR" "$MODULE_CACHE" "$OUTPUT_DIR"
/bin/rm -rf "$ICONSET_DIR"
/bin/mkdir -p "$ICONSET_DIR"
/usr/bin/sips -z 16 16 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
/usr/bin/sips -z 32 32 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
/usr/bin/sips -z 32 32 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
/usr/bin/sips -z 64 64 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
/usr/bin/sips -z 128 128 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
/usr/bin/sips -z 256 256 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
/usr/bin/sips -z 256 256 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
/usr/bin/sips -z 512 512 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
/usr/bin/sips -z 512 512 "$PROJECT_DIR/Packaging/AppIcon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
/bin/cp "$PROJECT_DIR/Packaging/AppIcon.png" "$ICONSET_DIR/icon_512x512@2x.png"
"$SWIFTC" \
    -O \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    "$PROJECT_DIR/Scripts/make-icon.swift" \
    -o "$BUILD_DIR/make-icon"
"$BUILD_DIR/make-icon" "$ICONSET_DIR" "$BUILD_DIR/AppIcon.icns"

"$SWIFTC" \
    -O \
    -whole-module-optimization \
    -module-cache-path "$MODULE_CACHE" \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    "$PROJECT_DIR"/Sources/MiniStat/*.swift \
    -o "$BUILD_DIR/MiniStat" \
    -framework AppKit \
    -framework IOKit \
    -framework ServiceManagement

/bin/rm -rf "$APP_PATH"
/bin/mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/bin/cp "$BUILD_DIR/MiniStat" "$APP_PATH/Contents/MacOS/MiniStat"
/bin/cp "$PROJECT_DIR/Packaging/Info.plist" "$APP_PATH/Contents/Info.plist"
/bin/cp "$BUILD_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
/usr/bin/plutil -lint "$APP_PATH/Contents/Info.plist"

/bin/rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

/bin/rm -f "$SOURCE_ZIP_PATH"
/usr/bin/zip -q -r "$SOURCE_ZIP_PATH" \
    Package.swift Sources Tests Scripts Packaging README.md build.sh test.sh .gitignore

echo "Built: $APP_PATH"
echo "Archive: $ZIP_PATH"
echo "Source: $SOURCE_ZIP_PATH"
