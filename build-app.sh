#!/bin/zsh
# Build "Preroll.app" - a menu bar app (no Dock icon).
set -e
cd "$(dirname "$0")"
APP="Preroll.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Preroll</string>
  <key>CFBundleDisplayName</key><string>Preroll</string>
  <key>CFBundleIdentifier</key><string>com.ksha23.preroll</string>
  <key>CFBundleExecutable</key><string>AirPlayLatency</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O src/MenuBarApp.swift -o "$APP/Contents/MacOS/AirPlayLatency"
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built: $PWD/$APP"
echo "run it with:  open \"$APP\""
echo "install with: cp -R \"$APP\" /Applications/"
