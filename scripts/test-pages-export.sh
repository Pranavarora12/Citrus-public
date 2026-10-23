#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/module-cache
if [[ "${1:-}" == "--build-app" ]]; then
  APP="$PWD/build/Citrus Pages Export Checks.app"
  mkdir -p "$APP/Contents/MacOS"
  xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -Onone -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" Sources/PagesIO.swift Tests/PagesExportHarness/main.swift -o "$APP/Contents/MacOS/PagesExportChecks" -framework AppKit
  cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>PagesExportChecks</string><key>CFBundleIdentifier</key><string>local.citrus.PagesExportChecks</string><key>CFBundleName</key><string>Citrus Pages Export Checks</string><key>CFBundlePackageType</key><string>APPL</string><key>NSAppleEventsUsageDescription</key><string>Verify saving generated test documents with Pages.</string></dict></plist>
PLIST
  codesign --force --sign - "$APP"
  exit 0
fi
xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -Onone -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" Sources/PagesIO.swift Tests/PagesExportHarness/main.swift -o build/pages-export-checks -framework AppKit
./build/pages-export-checks "$PWD/build/pages-export-results"
