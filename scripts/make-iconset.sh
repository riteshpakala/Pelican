#!/bin/bash
# WHAT: A macOS .iconset (ten sizes) from one 1024 px PNG.
# OUT:  <iconset dir>, ready for `iconutil -c icns`.
# PIN:  Left square. macOS 26 frames a legacy icon on its own rounded plate;
#       a pre-rounded PNG would show two sets of corners. On macOS 26+ the Dock
#       uses Support/AppIcon/AppIcon.icon (compiled by make-app.sh) instead; this
#       .icns is the CFBundleIconFile fallback.
#
#   ./scripts/make-iconset.sh Support/AppIcon/icon_1024.png build/AppIcon.iconset
#
set -e

SRC="${1:?usage: make-iconset.sh <1024px.png> <out.iconset>}"
OUT="${2:?usage: make-iconset.sh <1024px.png> <out.iconset>}"

rm -rf "$OUT"
mkdir -p "$OUT"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$SRC" --out "$OUT/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$SRC" --out "$OUT/icon_${size}x${size}@2x.png" >/dev/null
done
echo "iconset: $OUT"
