#!/bin/bash
# SysPet.app 빌드 → build/SysPet.app (Dock 아이콘 없는 앱)
set -e
cd "$(dirname "$0")"
A=build/SysPet.app/Contents
mkdir -p $A/MacOS
swiftc -O -o $A/MacOS/SysPet Sources/main.swift -framework AppKit -framework IOKit
cat > $A/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>SysPet</string>
<key>CFBundleIdentifier</key><string>lab.tools.syspet</string>
<key>CFBundleExecutable</key><string>SysPet</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
P
codesign -s - --force build/SysPet.app >/dev/null 2>&1 || true
echo "built: $(pwd)/build/SysPet.app"
