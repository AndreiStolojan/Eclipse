#!/bin/bash
# Build the app in Release, plus the `notch` CLI. `--beta` builds it as Eclipse Beta, with its own bundle ID and
# settings, so it can sit next to the stable app. install.sh calls this; it never installs anything.
#
# The app is signed ad hoc, so macOS sees each build as a new app and asks for its permissions again. With
# ECLIPSE_CODESIGN_IDENTITY set to a code signing certificate in your keychain (its name or SHA-1), the app is signed
# with it instead; macOS then ties permissions to that certificate and keeps them across updates. See the README.
set -euo pipefail
channel=stable
case "${1:-}" in
    "") ;;
    --beta) channel=beta ;;
    *) echo "Usage: $0 [--beta]" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo "Usage: $0 [--beta]" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "Eclipse requires macOS and Xcode." >&2; exit 1; }
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$channel" == beta ]]; then
    app_name="Eclipse Beta" bundle_id="ro.andrei.NotchLab.beta" id_suffix=".beta" name_suffix=" Beta" icon_suffix="-Beta"
    derived_data="$repo_dir/.build/DerivedData-beta"
else
    app_name="Eclipse" bundle_id="ro.andrei.NotchLab" id_suffix="" name_suffix="" icon_suffix=""
    derived_data="$repo_dir/.build/DerivedData"
fi
# The channel and the commit go into Info.plist through build settings, for the update check in Settings. A folder
# without git builds without a commit, which the app shows as a local build.
commit="$(git -C "$repo_dir" rev-parse --verify --quiet HEAD 2>/dev/null || true)"
# ARCH overrides the architecture, for a shell running under Rosetta on Apple silicon.
arch="${ARCH:-$(uname -m)}"
mkdir -p "$repo_dir/.build"
# Xcode adds com.apple.security.get-task-allow, which lets any process of the user attach a debugger, unless base
# entitlements are off; on the command line that also reaches the Swift package's framework. The channel suffixes
# are custom build settings the app target appends to its name, bundle ID and app icon set, so the Swift package
# targets keep their own names. Each channel has its own derived data: Xcode keeps old asset catalog output, so a
# shared folder would leave the other channel's icon in the app.
xcodebuild -project "$repo_dir/NotchLab.xcodeproj" -scheme 'Eclipse' -configuration Release \
    -derivedDataPath "$derived_data" -clonedSourcePackagesDirPath "$repo_dir/.build/SourcePackages" \
    -jobs 2 ARCHS="$arch" ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM= CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    CHANNEL_ID_SUFFIX="$id_suffix" CHANNEL_NAME_SUFFIX="$name_suffix" CHANNEL_ICON_SUFFIX="$icon_suffix" \
    ECLIPSE_CHANNEL="$channel" ECLIPSE_COMMIT="$commit" \
    build > "$repo_dir/.build/build.log" 2>&1 || {
        tail -60 "$repo_dir/.build/build.log" >&2; exit 1;
    }
app_path="$derived_data/Build/Products/Release/$app_name.app"
# Nested code first, then the app, so every part carries the certificate. The default designated requirement then
# names the bundle ID and the certificate, so only builds signed with the same certificate inherit the permissions.
if [[ -n "${ECLIPSE_CODESIGN_IDENTITY:-}" ]]; then
    echo "Signing with $ECLIPSE_CODESIGN_IDENTITY"
    for framework in "$app_path/Contents/Frameworks/"*.framework; do
        [[ -e "$framework" ]] || continue
        codesign --force --sign "$ECLIPSE_CODESIGN_IDENTITY" --timestamp=none "$framework"
    done
    codesign --force --sign "$ECLIPSE_CODESIGN_IDENTITY" --timestamp=none \
        --preserve-metadata=identifier,entitlements,flags "$app_path"
fi
codesign --verify --deep --strict "$app_path"
# Captured first: `grep -q` stops reading early, which fails a pipeline under pipefail even on a match.
signature="$(codesign --display --verbose=1 --requirements - "$app_path" 2>&1)"
grep -qx "Identifier=$bundle_id" <<< "$signature" || { echo "The app is not signed as $bundle_id." >&2; exit 1; }
# A requirement naming only the bundle ID would let any program signed with that ID inherit the app's permissions and
# Keychain items, so it must never come back.
if grep -qE '^(# )?designated => identifier "[^"]+"$' <<< "$signature"; then
    echo "The app's designated requirement names only its bundle ID." >&2; exit 1
fi
# No signed part of the release may be debuggable: the app, its frameworks, and any helper inside it, at any depth.
while IFS= read -r -d '' code; do
    entitlements="$(codesign --display --entitlements - --xml "$code" 2>/dev/null || true)"
    if grep -q 'com.apple.security.get-task-allow' <<< "$entitlements"; then
        echo "$code is signed with get-task-allow." >&2; exit 1
    fi
done < <(find "$app_path" \( -name '*.app' -o -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' \
    -o -name '*.appex' \) -print0)
echo "Built: $app_path"
# The notch CLI shares the socket parser with the app; it is not part of the app bundle. See docs/socket.md.
swiftc -O "$repo_dir/Sources/Notch/NotchMessage.swift" "$repo_dir/Tools/notch/main.swift" -o "$repo_dir/.build/notch"
echo "Built: $repo_dir/.build/notch"
