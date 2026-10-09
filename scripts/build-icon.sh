#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Convert the approved logo into every native macOS icon resolution.
output=${1:-"$PWD/dist/AppIcon.icns"}
stage=$(mktemp -d "${TMPDIR:-/tmp}/FinderSearch-icon.XXXXXX")
trap 'rm -rf "$stage"' EXIT
iconset="$stage/AppIcon.iconset"
mkdir -p "$iconset" "${output:h}"
swift scripts/render-icon.swift assets/logo.png "$stage/AppIcon.png" 1024
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/AppIcon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    retina=$((size * 2))
    sips -z "$retina" "$retina" "$stage/AppIcon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$output"
