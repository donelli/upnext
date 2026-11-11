#!/bin/sh
# Builds UpNext.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/UpNext.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O main.swift -o "$APP/Contents/MacOS/UpNext"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.upnext</string>
  <key>CFBundleName</key><string>UpNext</string>
  <key>CFBundleExecutable</key><string>UpNext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next meeting in the menu bar.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"  # ad-hoc sign so macOS remembers the calendar permission
mkdir -p ~/Applications && rm -rf ~/Applications/UpNext.app && cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/UpNext.app — run: open ~/Applications/UpNext.app"
