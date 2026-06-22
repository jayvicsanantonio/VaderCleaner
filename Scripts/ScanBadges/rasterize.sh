#!/bin/bash
# Regenerates the Smart Care badge SVGs and bakes each into a universal PNG
# imageset in the app's asset catalog, using rsvg-convert so the glossy
# gradients and soft shadows render on a transparent background (Quick Look
# bakes an opaque white background, which leaves white squares behind the orbs).
# Install the renderer with `brew install librsvg`. Re-run after editing
# generate_svgs.py or the SVG sources.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SVG_DIR="$DIR/svg"
ASSETS="$DIR/../../VaderCleaner/Assets.xcassets"
SIZE=256

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found — run: brew install librsvg"; exit 1; }

python3 "$DIR/generate_svgs.py"

for svg in "$SVG_DIR"/*.svg; do
  base="$(basename "$svg" .svg)"
  cap="$(printf '%s' "${base:0:1}" | tr '[:lower:]' '[:upper:]')${base:1}"
  asset="scanBadge${cap}"
  set_dir="$ASSETS/${asset}.imageset"
  mkdir -p "$set_dir"

  # -w/-h set the output pixel size; the background stays transparent.
  rsvg-convert -w "$SIZE" -h "$SIZE" "$svg" -o "$set_dir/${asset}.png"

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
