# Third-party assets and dependencies

Citrus application source is licensed under [MIT](LICENSE). Third-party components retain their own licenses and notices; the application license does not relicense them.

| Component | Purpose | Recorded provenance and notices |
| --- | --- | --- |
| Software image runtime | SVG, AVIF, and HEIC decoding | [Runtime README](Resources/ConversionRuntime/README.md), [libvips notices](Resources/ConversionRuntime/Licenses/LIBVIPS-THIRD-PARTY-NOTICES.md), component manifests, and license texts in `Resources/ConversionRuntime/Licenses/` |
| `image-decoder.c` | Citrus helper calling the libvips public API | [Helper MIT license](Resources/ConversionRuntime/Licenses/CITRUS-HELPER-LICENSE.txt) |
| `PowerPointBlank.pptx` | Standard OOXML master/layout/theme graph for PDF-to-PPTX | Locally generated using python-pptx; [provenance](Resources/PowerPointBlank.provenance.txt), [MIT notice](Resources/PowerPointTemplate-LICENSE.txt) |
| `AppIcon.png` | App, menu bar, and About artwork | Artwork supplied for Citrus during development; no separate license statement is recorded |
| FFmpeg, FFprobe, cwebp | External media processing and WebP encoding | Installed separately under `/opt/homebrew/bin/`; not bundled by the build scripts |

Apple Pages is an optional, separately installed application used through its scripting interface for `.pages` export. No Apple Pages template or application file is included. The app has no bundled hover audio.

Keep upstream notices with codec binaries and the OOXML baseline. The runtime README records component versions, source references, and the limits of the current source packaging. Review the codec distribution's corresponding-source requirements before distributing binary releases.
