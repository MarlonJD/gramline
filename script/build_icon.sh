#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ICON_SOURCE="$ROOT_DIR/Resources/Brand/Gramline.png"
ICON_SET="$ROOT_DIR/.build/Gramline.iconset"
mkdir -p "$ICON_SET"
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}.png" >/dev/null
  retina=$((size * 2))
  /usr/bin/sips -z "$retina" "$retina" "$ICON_SOURCE" --out "$ICON_SET/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil -c icns "$ICON_SET" -o "$ROOT_DIR/.build/Gramline.icns"
