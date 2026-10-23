# Validation

Run the automated checks with:

```sh
./scripts/test.sh
```

The suites generate fixtures and verify output readability, conversion content,
image geometry, PDF pages/text, audio/video processing, invalid inputs, and
preservation of source bytes. See [development](development.md) for individual
checks, the conversion matrix audit, and native GUI harnesses.

## Coverage

- Integrated regression suite, including PDF tools and missing-Pages/overwrite protection.
- Image tools: rendering, geometry, adjustments, compression, and metadata.
- Video tools: dispatch, trim, crop, mute, speed, snapshots, split/join, and redaction.
- Audio trim: waveform data, selection, silence trimming, and exported duration.

## Environment limits

Native pasteboard checks and Vision text detection can be unavailable in a
headless session. Playback, global drag/modifier interaction, visual appearance,
haptics, and system sharing need a logged-in desktop session. Offscreen previews
and CPU benchmarks do not measure on-screen frame rate.

Passing fixture checks establishes the tested output properties. It does not
guarantee arbitrary-file fidelity, full Office layout preservation, or support
for every codec configuration. See [features](features.md) for format limits.

## Native Pages verification

The desktop Pages export harness creates actual documents through installed Pages.
Four roundtrips passed on October 23, 2026: Unicode and quoted text, mixed newline
styles, an empty document, and text without a final newline. A headless shell can
fail macOS application registration even when the same native harness succeeds
in a logged-in desktop session.
