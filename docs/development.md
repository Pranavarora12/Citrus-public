# Development

## Source map

| Area | Main files in `Sources/` |
| --- | --- |
| Startup, menu bar, dispatch, shelves | `main.swift`, `CitrusApp.swift`, `AppBrand.swift` |
| Wheel presentation and drag lifecycle | `WheelDropView.swift`, `WheelShortcut.swift`, `WheelDismissal.swift` |
| Jobs and folder access | `ProcessingJob.swift`, `FolderAccessStore.swift` |
| Settings and format relationships | `SettingsView.swift`, `SettingsCatalog.swift`, `Settings*View.swift`, `SettingsFormatPane.swift` |
| Document import and export | `DocumentEngine.swift`, `DocumentImport.swift`, `DocumentLayoutWriter.swift`, `OfficeConversion.swift`, `PagesIO.swift` |
| Media and software image conversion | `MediaEngine.swift`, `NativeImageConversion.swift` |
| Image editors | `ImageTools.swift`, `ImagePixels.swift`, `ImageEditor.swift`, `ImageToolPanels.swift`, `ImageValueSlider.swift` |
| PDF editors | `PDFTools.swift`, `PDFCompression.swift`, `PDFEditor.swift`, `PDFToolPanels.swift` |
| Video editors | `VideoTools.swift`, `VideoEditor.swift`, `VideoToolPanels.swift` |
| Audio trim | `AudioTrim.swift` |
| Built-in diagnostics | `SelfTests.swift`, `*Tests.swift`, `*Preview.swift`, `WheelBenchmark.swift` |

The current build compiles `Sources/*.swift` directly. Keep that layout unless the build scripts and resource fallbacks based on `#filePath` are updated together. Built-in test and preview entry points remain in the application to preserve the existing command-line interface.

## Build

Run `./scripts/build.sh` from any working directory. Scripts resolve the checkout relative to their own location. The build targets `arm64-apple-macosx13.0`, generates the ICNS icon, copies resources while preserving library symlinks, and ad hoc signs the nested runtime and app bundles. No dependencies are downloaded during the build. Swift file/debug path prefixes are remapped to relative paths so compiled app code does not embed the checkout’s absolute location.

The external executables currently expected are `/opt/homebrew/bin/ffmpeg`, `/opt/homebrew/bin/ffprobe`, and `/opt/homebrew/bin/cwebp`. Check these paths before diagnosing media failures. The software decoder runtime is bundled; see its [README](../Resources/ConversionRuntime/README.md) for packaging and component provenance.

Wheel feedback uses haptics only. Native Pages export uses the installed Pages application and may request macOS Automation permission; it does not use a bundled document template. The scripting operation creates and closes only its own temporary document.

## Automated checks

```sh
./scripts/test.sh
```

This builds the app, copies its executable outside the bundle to avoid LaunchServices registration during headless tests, and runs integrated, image, PDF, video, and audio checks. Tests generate their own inputs and outputs. Integrated fixtures are temporary; tool audits remain under ignored `build/` for inspection. Pasteboard, Vision, playback, and other native services can require a desktop session; inspect any reported skips.

## Conversion matrix audit

```sh
./scripts/build-conversion-audit.sh
python3 scripts/run-conversion-audit.py
```

The audit generates fixtures and submits conversions through `AppModel.submitWheelDrop`. Reports and outputs go to `build/conversion-audit/`. Missing genuine fixtures are reported as `UNTESTED`, never as passing. The optional legacy XLS fixture comes from an installed Numbers application. Set `CITRUS_AUDIT_PAGES=1` to create a Pages fixture using the installed Pages app; otherwise Pages inputs are reported as untested.

Limit a run to source extensions or one target:

```sh
python3 scripts/run-conversion-audit.py png jpg --target=pdf
python3 scripts/run-conversion-audit.py --report-only
```

Filtered runs retain existing results for other pairs. Report-only mode uses saved results without running conversions. Validation checks readable output and known sample content; it does not certify arbitrary-file fidelity or native Finder gestures.

## Native GUI harnesses

Run the automated checks first to generate image, video, and audio fixtures. Build the desired harness, then open its app in a logged-in desktop session:

| Script | Generated app under `build/` |
| --- | --- |
| `build-wheel-tests.sh` | `Citrus Wheel Checks.app` |
| `build-image-live-checks.sh` | `Citrus Image Fix Checks.app` |
| `build-pdf-live-checks.sh` | `Citrus PDF Checks.app` |
| `build-video-live-checks.sh` | `Citrus Video Checks.app` |
| `build-audio-live-checks.sh` | `Citrus Audio Checks.app` |

The PDF harness lets you choose a local PDF. The video harness uses generated fixtures by default and lets you choose a local reference video. Harness exports stay in dedicated folders under `build/`. The wheel harness writes `build/wheel-tests.log` and requires native pasteboard access.

## Contributing

Keep runtime resources and third-party notices together. Do not commit `build/`, generated app bundles, recordings, personal documents, logs, credentials, or machine-specific configuration. Describe the observable behavior changed by a contribution and run the relevant existing checks. Changes to conversions should verify output readability and preservation of source bytes.

## Native Pages export checks

Run `./scripts/test-pages-export.sh` in a logged-in desktop session with Pages installed. If the shell cannot register native applications, run `./scripts/test-pages-export.sh --build-app`, open `build/Citrus Pages Export Checks.app`, and click Run Pages export checks. It checks native document creation and text roundtrips for Unicode, quotes, mixed newline styles, empty input, and text without a final newline. Missing-application and existing-output checks run in the integrated suite without launching Pages.
