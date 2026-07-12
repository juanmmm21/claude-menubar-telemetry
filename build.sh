#!/bin/bash

# Exit on error
set -e

APP_NAME="ClaudeTelemetry"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

echo "=== Cleaning previous build ==="
rm -rf "$BUILD_DIR"

echo "=== Creating App Bundle Directory Structure ==="
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

echo "=== Processing App Icon ==="
if [ -f "src/AppIcon.png" ]; then
    echo "Creating AppIcon.icns from src/AppIcon.png..."
    mkdir -p "$BUILD_DIR/AppIcon.iconset"
    sips -s format png -z 16 16     src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_16x16.png" > /dev/null 2>&1
    sips -s format png -z 32 32     src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_16x16@2x.png" > /dev/null 2>&1
    sips -s format png -z 32 32     src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_32x32.png" > /dev/null 2>&1
    sips -s format png -z 64 64     src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_32x32@2x.png" > /dev/null 2>&1
    sips -s format png -z 128 128   src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_128x128.png" > /dev/null 2>&1
    sips -s format png -z 256 256   src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_128x128@2x.png" > /dev/null 2>&1
    sips -s format png -z 256 256   src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_256x256.png" > /dev/null 2>&1
    sips -s format png -z 512 512   src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_256x256@2x.png" > /dev/null 2>&1
    sips -s format png -z 512 512   src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_512x512.png" > /dev/null 2>&1
    sips -s format png -z 1024 1024 src/AppIcon.png --out "$BUILD_DIR/AppIcon.iconset/icon_512x512@2x.png" > /dev/null 2>&1
    
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$BUILD_DIR/AppIcon.iconset"
    echo "AppIcon.icns generated successfully."
else
    echo "No src/AppIcon.png found. Skipping icon generation."
fi

echo "=== Compiling Swift Sources ==="
swiftc -o "$MACOS_DIR/$APP_NAME" \
    src/main.swift \
    src/AppDelegate.swift \
    src/DashboardView.swift \
    src/TelemetryManager.swift \
    src/AccountUsageService.swift \
    src/LaunchAtLoginService.swift \
    src/Theme.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
    -framework Security \
    -framework ServiceManagement \
    -O

echo "=== Generating Info.plist ==="
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.juanmmm21.$APP_NAME</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <string>true</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "=== Build Successful! ==="
echo "You can launch the app using: open $APP_DIR"
