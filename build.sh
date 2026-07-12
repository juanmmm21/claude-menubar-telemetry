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

echo "=== Compiling Swift Sources ==="
swiftc -o "$MACOS_DIR/$APP_NAME" \
    src/main.swift \
    src/AppDelegate.swift \
    src/DashboardView.swift \
    src/TelemetryManager.swift \
    src/Theme.swift \
    -framework Cocoa \
    -framework SwiftUI \
    -framework Combine \
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
