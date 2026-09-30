#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ICON_SOURCE=${1:-$ROOT/Assets/AppIcon.png}
ICON_TARGET=${2:-$ROOT/.build/Icon.icns}
ICONSET="$ROOT/.build/FrigateClient.iconset"
mkdir -p "$ICONSET" "$(dirname "$ICON_TARGET")"

for size in 16 32 128 256 512; do
  sips --resampleHeightWidth "$size" "$size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips --resampleHeightWidth "$double_size" "$double_size" "$ICON_SOURCE" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$ICON_TARGET" "$ICONSET"
