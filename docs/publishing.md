# Publishing

## Source distribution

Citrus application source uses the [MIT license](../LICENSE). Third-party components
retain their own licenses; keep all notices and codec source/version manifests.
Include `Sources/`, `Resources/`, `Tests/`, `scripts/`, and `docs/`, together with
the README, LICENSE, and third-party notices. Keep runtime libraries and symlinks:
they are required conversion dependencies.

Generated app bundles, test outputs, and release archives are excluded by
`.gitignore`. Review the staged file list before publishing a source repository.

## App releases

Build with `./scripts/build.sh`, then package `Citrus Desktop.app` as a ZIP for
GitHub Releases. Document Apple Silicon/macOS requirements, the external FFmpeg,
FFprobe and cwebp executables, and the optional Pages installation/Automation
requirement described in the [README](../README.md).

No hover audio or Apple Pages template is included. Native Pages export uses a
separately installed Pages application through its scripting interface.

Current signatures are ad hoc; Developer ID signing and notarization are not
configured. Codec binary redistribution retains its upstream license and
corresponding-source requirements; see the [runtime README](../Resources/ConversionRuntime/README.md).
