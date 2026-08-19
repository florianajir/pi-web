#!/bin/sh
# Regenerate homepage's favicon set from config/homepage/icons/pi.svg.
#
# Why the rasters exist at all: homepage's `favicon:` setting only takes effect
# after client-side hydration (it reads from SettingsProvider, see src/pages/_app.jsx),
# so the server-rendered HTML still points at the stock /favicon-*.png, /homepage.ico
# and /apple-touch-icon.png. Browsers latch onto those first and frequently never
# re-read the swapped <link>. compose.yaml bind-mounts the files generated here over
# the stock ones in /app/public so the pi glyph is correct from the first byte.
#
# Only needs re-running when pi.svg changes.
set -eu

cd "$(dirname "$0")/.."
ICONS=config/homepage/icons
SRC=$ICONS/pi.svg

for bin in rsvg-convert convert; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

render() { rsvg-convert -w "$1" -h "$1" "$SRC" -o "$ICONS/$2"; echo "  $2 (${1}px)"; }

echo "Rendering from $SRC:"
render 16 favicon-16x16.png
render 32 favicon-32x32.png
render 180 apple-touch-icon.png
render 192 android-chrome-192x192.png
render 512 android-chrome-512x512.png

# Multi-resolution .ico. Each frame is rendered from the SVG at its own size rather
# than resampled from one raster, so none of them is a blurry up- or downscale.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for size in 16 32 48; do
  rsvg-convert -w $size -h $size "$SRC" -o "$tmp/$size.png"
done
convert "$tmp/48.png" "$tmp/32.png" "$tmp/16.png" "$ICONS/homepage.ico"
echo "  homepage.ico (48,32,16)"

# /favicon.ico is not in homepage's HTML, but browsers request it as a last resort
# (and would 404 here), so cover that path too.
cp "$ICONS/homepage.ico" "$ICONS/favicon.ico"
echo "  favicon.ico"

cp "$ICONS/pi-mask.svg" "$ICONS/safari-pinned-tab.svg"
echo "  safari-pinned-tab.svg"
