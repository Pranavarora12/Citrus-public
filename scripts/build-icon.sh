#!/bin/zsh
set -eu
cd "${0:A:h:h}"
ICONSET="$PWD/build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
# ICNS consists of typed, length-prefixed PNG representations. Writing those
# directly also works in sessions where iconutil cannot access IconServices.
/usr/bin/python3 - <<'PY'
from pathlib import Path
import struct
root = Path('build/AppIcon.iconset')
representations = [
    ('icp4', '16x16'), ('ic11', '16x16@2x'),
    ('icp5', '32x32'), ('ic12', '32x32@2x'),
    ('ic07', '128x128'), ('ic13', '128x128@2x'),
    ('ic08', '256x256'), ('ic14', '256x256@2x'),
    ('ic09', '512x512'), ('ic10', '512x512@2x'),
]
chunks = []
for kind, name in representations:
    png = (root / ('icon_' + name + '.png')).read_bytes()
    chunks.append(kind.encode('ascii') + struct.pack('>I', len(png) + 8) + png)
body = b''.join(chunks)
Path('build/AppIcon.icns').write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
PY
