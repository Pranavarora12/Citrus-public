#!/bin/zsh
set -eu
cd "${0:A:h:h}"
mkdir -p build/conversion-audit build/module-cache
sources=(Sources/*.swift)
sources=(${sources:#Sources/main.swift})
xcrun swiftc -file-prefix-map "${PWD}=." -debug-prefix-map "${PWD}=." -swift-version 5 -O -target arm64-apple-macosx13.0 -module-cache-path "$PWD/build/module-cache" $sources Tests/ConversionAudit.swift Tests/ConversionAuditRunner/main.swift -o build/conversion-audit/runner -framework SwiftUI -framework AppKit -framework PDFKit -framework Vision -framework AVFoundation -framework ImageIO -framework UniformTypeIdentifiers -framework CoreImage
