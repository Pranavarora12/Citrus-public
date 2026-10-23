# Citrus software image runtime

This directory is a minimal, relocatable Apple Silicon macOS runtime for software
image decoding. Total size is approximately 23 MB.

- `dependencies/native/libvips/bin/image-decoder`: original Citrus C helper;
  source is alongside it. Rebuild using `clang -O2 -mmacosx-version-min=13.0
  image-decoder.c -o bin/image-decoder`. It uses only libvips's public C API.
- `dependencies/native/libvips/lib/libvips-cpp.8.18.7.dylib`: unmodified upstream
  prebuilt library from `@img/sharp-libvips-darwin-arm64` 1.3.4. Supports SVG via
  librsvg and AVIF via libheif/AOM; links only system libraries. No Node runtime
  or sharp JavaScript package is required. Upstream notices and exact component
  versions are copied into `Licenses`.
- `dependencies/native/libheif/libheif`: unmodified libheif 1.23.2 command-line
  decoder and its required runtime libraries, copied with relative symlinks.
  Source archive URL and SHA256 are recorded in `Licenses/libheif-manifest.json`.
  HEVC decoding uses libde265 1.1.1. HEVC encoding is performed by the installed
  Homebrew FFmpeg/x265; Citrus builds the HEIF container in Swift.

Runtime resolution prefers `Citrus.app/Contents/Resources/ConversionRuntime`,
then the checkout's `Resources/ConversionRuntime`, then the installed Codex cache
as a development fallback. Helpers and libraries use relative loader paths.
The image helper runs as a separate process; no codec library is loaded into
Citrus itself. Homebrew FFmpeg and cwebp remain external dependencies.

## Licensing and provenance

`Licenses/LIBVIPS-THIRD-PARTY-NOTICES.md` is the upstream package's own license
inventory. The shared libvips distribution and several of its bundled libraries
are used under LGPLv3, including the later-version clauses described in that
inventory. Generic LGPLv3, GPLv3, and LGPLv2.1 license texts are included, along
with locally available libjpeg-turbo and libpng license texts. The libheif and
libde265 libraries use LGPL licenses; other decoder dependencies include the
libjpeg-turbo, libpng, zlib, and LLVM libc++ license families. The source manifest
records the exact libheif source, and the libvips version manifest records all
statically bundled components. Upstream sources and build recipes are available
from https://github.com/lovell/sharp-libvips and
https://github.com/strukturag/libheif. This locally assembled runtime preserves
available upstream notices; it is not a complete source-code distribution.

The original `image-decoder.c` helper may be used under the MIT license included
in `Licenses/CITRUS-HELPER-LICENSE.txt`. Codec libraries retain their own licenses.

## Application packaging

Copy this whole directory preserving symlinks. Sign each real `.dylib`, then the
`image-decoder` and `heif-dec` Mach-O executables, before signing the enclosing
application. Existing ad-hoc signatures may be replaced with the app's signing
identity. Do not strip libraries without re-signing them. No install-name
rewrites or absolute cache paths are needed. The files are arm64 builds.
