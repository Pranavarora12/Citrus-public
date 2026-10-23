#!/bin/zsh
set -eu
cd "${0:A:h:h}"
APP="$PWD/build/Citrus.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/build/module-cache"
./scripts/build-icon.sh
xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" Sources/*.swift -o "$APP/Contents/MacOS/Citrus.next" -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage
mv "$APP/Contents/MacOS/Citrus.next" "$APP/Contents/MacOS/Citrus"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Citrus</string><key>CFBundleIdentifier</key><string>local.reaprac.Citrus</string><key>CFBundleName</key><string>Citrus</string><key>CFBundleDisplayName</key><string>Citrus</string><key>CFBundleShortVersionString</key><string>0.4.1</string><key>CFBundlePackageType</key><string>APPL</string><key>LSMinimumSystemVersion</key><string>13.0</string><key>NSHighResolutionCapable</key><true/><key>LSUIElement</key><true/></dict></plist>
PLIST
plutil -replace CFBundleShortVersionString -string 0.4.1 "$APP/Contents/Info.plist"
plutil -insert CFBundleIconFile -string AppIcon "$APP/Contents/Info.plist"
# Remove retired assets from incremental builds.
rm -f "$APP/Contents/Resources/WheelHighlight.mp3" "$APP/Contents/Resources/WheelHighlight.provenance.txt" "$APP/Contents/Resources/PagesBlank.pages" "$APP/Contents/Resources/PagesBlank.provenance.txt"
cp Resources/AppIcon.png build/AppIcon.icns "$APP/Contents/Resources/"
if [[ -d Resources/ConversionRuntime ]]; then
  RUNTIME="$APP/Contents/Resources/ConversionRuntime"
  ditto Resources/ConversionRuntime "$RUNTIME"
  for binary in "$RUNTIME"/**/*.dylib(.N) "$RUNTIME/dependencies/native/libvips/bin/image-decoder" "$RUNTIME/dependencies/native/libheif/libheif/bin/heif-dec"; do
    codesign --force --sign - "$binary"
  done
fi
cp Resources/PowerPointBlank.pptx "$APP/Contents/Resources/PowerPointBlank.pptx"
cp Resources/PowerPointBlank.provenance.txt Resources/PowerPointTemplate-LICENSE.txt "$APP/Contents/Resources/"
plutil -insert NSAppleEventsUsageDescription -string "Citrus uses Pages to save files in the Pages document format." "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
DESKTOP_APP="$PWD/Citrus Desktop.app"
STAGING_APP="$PWD/build/Citrus Desktop Staging.app"
ditto "$APP" "$STAGING_APP"
plutil -replace CFBundleIdentifier -string local.reaprac.CitrusDesktop "$STAGING_APP/Contents/Info.plist"
plutil -replace CFBundleName -string 'Citrus Desktop' "$STAGING_APP/Contents/Info.plist"
plutil -replace CFBundleDisplayName -string 'Citrus Desktop' "$STAGING_APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string 0.4.1 "$STAGING_APP/Contents/Info.plist"
codesign --force --sign - "$STAGING_APP"
PREVIOUS_APP="$PWD/build/Citrus Desktop Previous-$(date +%Y%m%d-%H%M%S).app"
if [[ -d "$DESKTOP_APP" ]]; then
  mv "$DESKTOP_APP" "$PREVIOUS_APP"
fi
if ! mv "$STAGING_APP" "$DESKTOP_APP"; then
  if [[ -d "$PREVIOUS_APP" ]]; then mv "$PREVIOUS_APP" "$DESKTOP_APP"; fi
  exit 1
fi
printf 'Desktop app: %s\n' "$DESKTOP_APP"
