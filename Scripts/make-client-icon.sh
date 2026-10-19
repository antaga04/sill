#!/bin/bash
# Sill Viewer's icon: design/ViewerIcon.svg (Sill's art with the viewer's pointer badge) rendered by
# Quick Look, put on macOS's icon grid by client-icon-mask.swift, scaled by sips and packed by
# iconutil into .build/client-icon/AppIcon.icns. Command Line Tools are enough (no actool). Cached
# until the SVG or these scripts change. Prints the .icns path.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/.build/client-icon"
icns="$out/AppIcon.icns"
svg=design/ViewerIcon.svg
if [ -f "$icns" ] && [ "$icns" -nt "$svg" ] && [ "$icns" -nt "$0" ] && [ "$icns" -nt Scripts/client-icon-mask.swift ]; then
    echo "$icns"; exit 0
fi
rm -rf "$out"; mkdir -p "$out/AppIcon.iconset"
qlmanage -t -s 1024 -o "$out" "$PWD/$svg" >/dev/null 2>&1 || true
[ -f "$out/ViewerIcon.svg.png" ] || { echo "error: Quick Look did not render $svg" >&2; exit 1; }
swiftc -O Scripts/client-icon-mask.swift -o "$out/mask" 2>/dev/null
"$out/mask" "$out/ViewerIcon.svg.png" "$out/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$out/icon-1024.png" --out "$out/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$out/icon-1024.png" --out "$out/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$out/AppIcon.iconset" -o "$icns"
echo "$icns"
