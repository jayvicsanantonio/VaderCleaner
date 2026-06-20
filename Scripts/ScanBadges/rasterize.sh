#!/bin/bash
# Regenerates the Smart Care badge SVGs and bakes each into a universal PNG
# imageset in the app's asset catalog, using macOS Quick Look to rasterize the
# glossy gradients and soft shadows. Re-run after editing generate_svgs.py or
# the SVG sources.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SVG_DIR="$DIR/svg"
ASSETS="$DIR/../../VaderCleaner/Assets.xcassets"
SIZE=256

python3 "$DIR/generate_svgs.py"

for svg in "$SVG_DIR"/*.svg; do
  base="$(basename "$svg" .svg)"
  cap="$(printf '%s' "${base:0:1}" | tr '[:lower:]' '[:upper:]')${base:1}"
  asset="scanBadge${cap}"
  set_dir="$ASSETS/${asset}.imageset"
  mkdir -p "$set_dir"

  tmp="$(mktemp -d)"
  qlmanage -t -s "$SIZE" -o "$tmp" "$svg" >/dev/null 2>&1
  mv "$tmp/${base}.svg.png" "$set_dir/${asset}.png"
  rm -rf "$tmp"

  cat > "$set_dir/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "${asset}.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  echo "baked ${asset}.imageset"
done
