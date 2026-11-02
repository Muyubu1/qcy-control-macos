#!/bin/zsh
set -e
cd "$(dirname "$0")"
APP="QCY Kontrol.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -target arm64-apple-macos13 QCYKontrol.swift -framework IOBluetooth -o "$APP/Contents/MacOS/QCYKontrol"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.yusufbulut.qcykontrol</string>
<key>CFBundleName</key><string>QCY Kontrol</string>
<key>CFBundleExecutable</key><string>QCYKontrol</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>QCY kulaklığınızın ayarlarını değiştirmek için Bluetooth gerekiyor.</string>
</dict></plist>
PL
codesign --force --deep -s - "$APP"
echo "OK: $PWD/$APP"
