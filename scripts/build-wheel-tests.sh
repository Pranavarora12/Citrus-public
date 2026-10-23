#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_APP="$PWD/build/Citrus Wheel Checks.app"
mkdir -p "$TEST_APP/Contents/MacOS"
SOURCES=(Sources/*.swift)
SOURCES=(${SOURCES:#Sources/main.swift})
xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" $SOURCES Tests/GuiHarness/main.swift -o "$TEST_APP/Contents/MacOS/WheelTests" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>WheelTests</string><key>CFBundleIdentifier</key><string>local.reaprac.CitrusWheelChecks</string><key>CFBundleName</key><string>Citrus Wheel Checks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
mkdir -p "$TEST_APP/Contents/Resources"
cp Tests/Fixtures/sample.png "$TEST_APP/Contents/Resources/sample.png"
rm -f "$TEST_APP/Contents/Resources/WheelHighlight.mp3"
codesign --force --sign - "$TEST_APP"
