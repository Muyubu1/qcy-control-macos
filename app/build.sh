#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="QCY Control.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos13 QCYControl.swift -framework IOBluetooth -o "$APP/Contents/MacOS/QCYControl"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.github.muyubu1.qcycontrol</string>
<key>CFBundleName</key><string>QCY Control</string>
<key>CFBundleExecutable</key><string>QCYControl</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>Bluetooth is needed to change your QCY earbuds' settings.</string>
</dict></plist>
PL
codesign --force --deep -s - "$APP"
echo "OK: $PWD/$APP"
