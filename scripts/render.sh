#!/bin/bash
# Render the notch views from fixed demo data (`--render`) to .build/renders, and copy the ones the README shows to
# docs/images. The app builds under a throwaway bundle ID, so no installed Eclipse's settings show up in the images,
# and its preferences are deleted afterwards. Live readings (volume, brightness, audio devices) come from this Mac;
# the README images do not use them.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="ro.andrei.NotchLab.render"
out_dir="$repo_dir/.build/renders"
xcodebuild -project "$repo_dir/NotchLab.xcodeproj" -scheme 'Eclipse' -configuration Debug \
    -derivedDataPath "$repo_dir/.build/RenderData" -clonedSourcePackagesDirPath "$repo_dir/.build/SourcePackages" \
    ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= \
    CHANNEL_ID_SUFFIX=.render CHANNEL_NAME_SUFFIX=" Render" \
    build > "$repo_dir/.build/render-build.log" 2>&1 || { tail -40 "$repo_dir/.build/render-build.log" >&2; exit 1; }
rm -rf "$out_dir"
mkdir -p "$out_dir"
trap 'defaults delete "$bundle_id" >/dev/null 2>&1 || true' EXIT
NOTCH_RENDER_DIR="$out_dir" "$repo_dir/.build/RenderData/Build/Products/Debug/Eclipse Render.app/Contents/MacOS/Eclipse Render" --render
# The README's images: render name, then the name under docs/images.
readme_images=(
    readme-hero:hero.png
    readme-now-playing:now-playing.png
    readme-indicators:indicators.png
    readme-calendar:calendar.png
    readme-timer:timer.png
    readme-shelf:shelf.png
    readme-downloads:downloads.png
    native-lock-media-glass:lock-screen.png
)
rm -rf "$repo_dir/docs/images"
mkdir -p "$repo_dir/docs/images"
for pair in "${readme_images[@]}"; do
    cp "$out_dir/${pair%%:*}.png" "$repo_dir/docs/images/${pair#*:}"
done
echo "README images updated in docs/images"
