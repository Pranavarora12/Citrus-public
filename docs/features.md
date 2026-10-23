# Features and limitations

## Wheels and settings

Citrus runs in the menu bar with one Settings window: General, Formats, Compatibility, Folders, and About. General controls wheel shortcuts, appearance, and haptic feedback. Formats provides searchable defaults for 46 catalog entries. Folder grants are stored as security-scoped bookmarks.

Conversion choices come from `Sources/SettingsCatalog.swift` and are intersected across every selected input. The compatibility grid describes catalog relationships, not a guarantee of fidelity for every possible file or installed codec.

## Tools

| Input | Command-wheel tools | Output behavior |
| --- | --- | --- |
| Images | Compress, Metadata, Edit, Annotate, Add BG, Crop, Redact | New copies; editing normally flattens to PNG; compression preserves transparency as PNG and uses JPEG for opaque images |
| PDF | Compress, Metadata, Split, Organize, QR Code | New PDFs or a uniquely named pages folder; QR opens HTTP/HTTPS links and displays other payloads as text |
| Video | Compress, Metadata, Mute, Trim, Crop, Speed, Snapshots, Split, Redact; Join for multiple videos | Editing normally writes MP4/H.264/AAC; mute and metadata retain the source container where supported; snapshots are PNG |
| Audio | Trim | Waveform editor, draggable range, selected-range playback, optional silence trimming; new WAV |

Image editing includes 22 adjustments, live preview, zoom, and original comparison. Annotation supports text, shapes, arrows, pen, highlighting, numbered markers, magnifiers, and placed images with move/resize/undo/redo. Backgrounds support solid, gradient, or custom artwork with padding, rounded corners, shadow, and canvas ratios. Crop uses source-pixel coordinates and aspect presets. Redaction supports solid/blur regions and local face/text detection.

PDF organization supports thumbnail reordering, clockwise rotation, reset, and proportional scaling to the narrowest final page width. Split writes `<source name> Pages/Page 1.pdf`, etc. Compression checks actual output bytes and may rasterize pages, reduce resolution, or quantize colors to meet a target. An unreachable target reports an error.

Video editors provide playback, timeline/frame selection, crop geometry, speed controls, snapshots, timed solid/blur redaction, and split clips. Split can export separate clips or concatenate retained segments. Join offers input ordering and adds silence for sources without audio. Metadata offers searchable editable tags, individual removal, Remove All, and Reset; container writers may regenerate technical tags.

Audio automatic trimming detects samples above −40 dB and keeps 10 ms padding within the selected range. Entirely silent selections cannot be exported with automatic trimming enabled. Each selected audio file opens its own editor.

## File actions

AirDrop uses system sharing. Copy and Copy Paths write to the clipboard. Move uses a destination picker and moves originals. Open Terminal uses the configured terminal application. Float creates a shelf with file drag/drop, open, reveal, copying, and reference removal. Advanced shelf multi-selection, collapse, and edge docking are not implemented.

## Conversion boundaries

- **Documents:** rich text exports may reflow and lose formatting, images, or layout. PDF-to-DOCX and EPUB offer text or page-artwork modes. Markdown is treated as plain text. Native Pages export requires the installed Pages app and macOS Automation permission. Pages creates the document through its scripting interface; no Apple template is bundled. Pages import is handled locally without launching Pages.
- **Presentations:** PDF-to-PPTX creates page-image slides with text descriptions. Original text and shapes are not editable objects. PPTX rendering handles ordinary text, pictures, fills, and groups; advanced themes, charts, transitions, and effects are not fully reproduced. Legacy PPT lacks a representative regression fixture.
- **Spreadsheets:** conversions use the first worksheet's values and cached formula results. Styles, merged-cell layout, and formula recalculation are not preserved. PDF-to-XLSX uses basic text row/column inference.
- **Images:** software HEIC export stores RGB without alpha or EXIF/XMP. Metadata preservation across software fallback paths is not established. SVG is input-only. Animation and HDR preservation are not guaranteed by still-image editing routes.
- **Media:** codecs depend on the installed FFmpeg build. Joins normalize video dimensions and frame rate. Timing is quantized to frames; extra tracks, HDR, and metadata may change.
- **Archives:** ZIP, TAR, and TAR.GZ can be written. RAR can be extracted and repackaged but cannot be written. GZIP archive output is a TAR.GZ container. Link-bearing or unsafe-path archives are rejected.
- **Metadata:** field removal is tested for supported cases; complete removal of every vendor-specific privacy block is not established.

The generic processing engine also contains operations beyond the visible tool wheels. Engine support does not imply a corresponding editor or wheel entry.
