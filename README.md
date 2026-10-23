# Citrus

Citrus is a native macOS menu bar utility for local file conversions, editing tools, and file actions. Drag files in Finder and press a modifier key to open the corresponding wheel.

| Default key | Wheel | Examples |
| --- | --- | --- |
| Shift | Conversions | Images, documents, spreadsheets, audio, video, subtitles, archives |
| Command | Tools | Image editing, PDF organization, video editing, audio trimming |
| Control | Actions | AirDrop, Float, Copy, Move, Copy Paths, Open Terminal |

Modifiers, appearance, haptic feedback, conversion defaults, and folder access are configurable in Settings. Processing runs locally. Conversion and editing outputs are saved as uniquely named copies on Desktop; successful operations are silent. The Move action moves the selected originals to the chosen folder.

## Requirements

- Apple Silicon Mac with macOS 13 or later. Intel builds are not currently provided.
- Xcode Command Line Tools, including Swift and the macOS SDK.
- FFmpeg, FFprobe, and cwebp installed at `/opt/homebrew/bin/`. These paths are currently fixed in the application.
- **For `.pages` export only:** Apple Pages installed locally, with permission for Citrus to control it under System Settings → Privacy & Security → Automation. Pages may open during export. Reading `.pages` files does not require the Pages app.

The checkout includes an Apple Silicon software image runtime, an OOXML presentation baseline, and the app icon in `Resources/`. Keep these required conversion resources. Wheel feedback is haptic only; the app bundles no hover audio or Apple Pages template.

## Build and run

From the project directory:

```sh
./scripts/build.sh
open "Citrus Desktop.app"
```

The build creates `build/Citrus.app` and a project-root `Citrus Desktop.app`. Both are generated, locally ad hoc signed bundles and are excluded from Git. Quit a running older version before opening a rebuilt copy. Closing Settings leaves Citrus running in the menu bar.

## Use

1. Start dragging one or more files in Finder.
2. Press Shift, Command, or Control to display a wheel.
3. Drop onto an option. Editors open for tools that need further input.

Conversion choices depend on the input formats; mixed selections offer only common outputs. Drag several images onto PDF to create one PDF in the supplied order. Audio exposes Trim as its only Command-wheel tool. Escape, an outside click, or ending a drag without selecting an option dismisses the wheel.

See [features and limitations](docs/features.md) for tool behavior and conversion fidelity.

## Development

```sh
./scripts/test.sh
```

The regression suites use generated fixtures and check real outputs, source preservation, and invalid inputs. Some native interactions require a desktop session. See [development](docs/development.md) for the source map, conversion audit, and GUI harnesses.

## Project layout

```text
Sources/      Swift application, processing engines, and built-in diagnostics
Resources/    Required runtime assets, templates, codec libraries, and notices
Tests/        Conversion audit, GUI harnesses, and a small test fixture
scripts/      Build and verification entry points
docs/         Feature, development, validation, and publishing notes
```

## Licensing

See [validation](docs/validation.md) for test coverage and supported verification environments.

Citrus application source is available under the [MIT license](LICENSE). Dependencies retain their own licenses; see [third-party notices](THIRD_PARTY_NOTICES.md). The app does not redistribute Apple Pages or its templates. See [publishing](docs/publishing.md) for release preparation and Git history guidance.
