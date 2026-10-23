#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TEST_APP="$PWD/build/Citrus PDF Checks.app"
mkdir -p "$TEST_APP/Contents/MacOS"
SOURCES=(Sources/*.swift)
SOURCES=(${SOURCES:#Sources/main.swift})
xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" $SOURCES Tests/PDFLiveHarness/main.swift -o "$TEST_APP/Contents/MacOS/PDFChecks" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PDFChecks</string><key>CFBundleIdentifier</key><string>local.reaprac.CitrusPDFChecks</string><key>CFBundleName</key><string>Citrus PDF Checks</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - "$TEST_APP"
