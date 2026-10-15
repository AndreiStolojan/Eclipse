#!/bin/bash
# Render design/NotchLab-icon.svg into the app icon sets in App/Assets.xcassets: AppIcon for Eclipse and AppIcon-Beta
# for Eclipse Beta, the same artwork tinted the window's teal accent. The build picks one through
# ASSETCATALOG_COMPILER_APPICON_NAME, so each app carries only its own. Needs rsvg-convert (brew install librsvg).
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
command -v rsvg-convert >/dev/null || { echo "Missing rsvg-convert: brew install librsvg" >&2; exit 1; }
source_svg="$repo_dir/design/NotchLab-icon.svg"
catalog="$repo_dir/App/Assets.xcassets"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

# The beta artwork: the corona, its glow and the bead in teal (#66d6bf); the shape is unchanged.
sed -e 's/stop offset=".55" stop-color="#ffffff"/stop offset=".55" stop-color="#bff1e6"/' \
    -e 's/stop offset=".62" stop-color="#e4e8f0"/stop offset=".62" stop-color="#66d6bf"/' \
    -e 's/stop-color="#8d97ab"/stop-color="#2f8f7c"/g' \
    -e 's/r="24" fill="#ffffff"/r="24" fill="#66d6bf"/' \
    -e 's/r="72" fill="#ffffff"/r="72" fill="#66d6bf"/' \
    "$source_svg" > "$work_dir/beta.svg"
cmp -s "$source_svg" "$work_dir/beta.svg" && { echo "The beta tint no longer matches the SVG." >&2; exit 1; }

# Writes one macOS icon set: 16 to 512 pt at 1x and 2x.
render_set() {
    local svg="$1" set_dir="$catalog/$2.appiconset" images="" size scale pixels suffix file
    rm -rf "$set_dir"
    mkdir -p "$set_dir"
    for size in 16 32 128 256 512; do
        for scale in 1 2; do
            pixels=$((size * scale))
            suffix=""
            [[ $scale == 1 ]] || suffix="@${scale}x"
            file="icon_${size}x${size}${suffix}.png"
            rsvg-convert -w "$pixels" -h "$pixels" "$svg" -o "$set_dir/$file"
            images+="${images:+,
}    { \"filename\" : \"$file\", \"idiom\" : \"mac\", \"scale\" : \"${scale}x\", \"size\" : \"${size}x${size}\" }"
        done
    done
    printf '{\n  "images" : [\n%s\n  ],\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' "$images" > "$set_dir/Contents.json"
}

mkdir -p "$catalog"
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > "$catalog/Contents.json"
render_set "$source_svg" AppIcon
render_set "$work_dir/beta.svg" AppIcon-Beta
echo "Wrote AppIcon and AppIcon-Beta in App/Assets.xcassets"
