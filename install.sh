#!/usr/bin/env bash
# Builds Eclipse from source and installs it. Run it from a clone (./install.sh) or straight from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Eclipse/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Eclipse/main/install.sh | bash -s -- --beta
# From a clone it builds that checkout as it is. Otherwise it keeps a checkout of the channel's branch in
# ~/Library/Caches/eclipse-install and updates it on every run.
set -euo pipefail

repo_url="${ECLIPSE_REPO:-https://github.com/AndreiStolojan/Eclipse.git}"
cache_root="$HOME/Library/Caches/eclipse-install"
# Written into the .git folder of every checkout this script clones. Only a checkout holding it is ever updated or
# deleted, so the script never resets or removes a repository it did not create.
owner_marker="eclipse-install-owner"
min_macos=15

usage() {
    cat <<'EOF'
Usage: install.sh [--beta] [--uninstall] [--help]

Builds Eclipse from source with Xcode and installs it to /Applications
(or ~/Applications when /Applications is not writable), then opens it.

  --beta       Build the beta branch as "Eclipse Beta", a separate app with
               its own settings. It can run next to the stable app.
  --uninstall  Quit and remove the app (with --beta: Eclipse Beta) and the
               build cache. Settings and permissions stay; the commands to
               remove them are printed.
  --help       Show this help.

Environment:
  ECLIPSE_REPO               Git URL to build from instead of the GitHub repository.
  ECLIPSE_CODESIGN_IDENTITY  Sign with this certificate so macOS keeps permissions
                             across updates (see the README).
EOF
}

if [[ -t 1 ]]; then bold=$'\033[1m' red=$'\033[31m' reset=$'\033[0m'; else bold="" red="" reset=""; fi
step() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
fail() { printf '%sError:%s %s\n' "$red" "$reset" "$*" >&2; exit 1; }

channel=stable
action=install
for arg in "$@"; do
    case "$arg" in
        --beta) channel=beta ;;
        --uninstall) action=uninstall ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [[ "$channel" == beta ]]; then
    app_name="Eclipse Beta" bundle_id="ro.andrei.NotchLab.beta" branch=beta build_flags=(--beta)
    derived_data=DerivedData-beta
else
    app_name="Eclipse" bundle_id="ro.andrei.NotchLab" branch=main build_flags=()
    derived_data=DerivedData
fi

# The bundle ID of the app at a path, empty when there is none.
bundle_id_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Where this app is installed now, if anywhere. Another app with the same name, such as the Eclipse IDE, is
# never touched.
installed_path() {
    local dir
    for dir in /Applications "$HOME/Applications"; do
        if [[ -d "$dir/$app_name.app" && "$(bundle_id_of "$dir/$app_name.app")" == "$bundle_id" ]]; then
            echo "$dir/$app_name.app"
            return
        fi
    done
}

# Quits the running app, if any: a polite TERM first, then KILL after about 5 s.
quit_app() {
    local pattern="/$app_name\\.app/Contents/MacOS/$app_name\$"
    pgrep -f "$pattern" >/dev/null || return 0
    step "Quitting $app_name"
    pkill -TERM -f "$pattern" || true
    for _ in {1..50}; do
        pgrep -f "$pattern" >/dev/null || return 0
        sleep 0.1
    done
    pkill -KILL -f "$pattern" || true
}

# Fails when the cache root or a checkout path under it is a symbolic link. The script resets and deletes these
# folders, so a link could aim it at another repository.
check_cache_paths() {
    local path
    for path in "$cache_root" "$@"; do
        [[ ! -L "$path" ]] || fail "$path is a symbolic link. The installer only manages a real folder there.
       Remove the link and run this again."
    done
}

# Whether a folder is a checkout this script cloned: a real .git folder that holds the owner marker.
owned_checkout() {
    [[ -d "$1/.git" && ! -L "$1/.git" && -f "$1/.git/$owner_marker" && ! -L "$1/.git/$owner_marker" ]]
}

uninstall() {
    local cache="$cache_root/$branch" path
    # Checked before anything is removed, so a refused cache leaves the app installed too.
    check_cache_paths "$cache"
    if [[ -e "$cache" ]] && ! owned_checkout "$cache"; then
        fail "$cache was not created by this installer, so it is left alone. Move it away and run this again."
    fi
    path="$(installed_path)"
    if [[ -n "$path" && ! ( -w "$(dirname "$path")" && -O "$path" ) ]]; then
        fail "$path cannot be removed without admin rights. Delete it in the Finder."
    fi
    quit_app
    if [[ -n "$path" ]]; then
        rm -rf "$path"
        step "Removed $path"
    else
        step "$app_name is not installed"
    fi
    if [[ -e "$cache" ]]; then
        rm -rf "$cache"
        rmdir "$cache_root" 2>/dev/null || true
    fi
    cat <<EOF

Settings and permissions are kept. To remove them too:
  defaults delete $bundle_id
  tccutil reset All $bundle_id
The Spotify and T3 Code sign-ins, if you used them, are in Keychain Access
under names starting with $bundle_id.
EOF
}

check_system() {
    [[ "$(uname -s)" == Darwin ]] || fail "Eclipse is a macOS app."
    [[ $EUID -ne 0 ]] || fail "Run this as your own user, not with sudo."
    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    (( major >= min_macos )) || fail "Eclipse needs macOS $min_macos or later; this Mac runs $version."
    # A shell under Rosetta reports x86_64 on Apple silicon; build for the real CPU.
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" == 1 ]]; then
        export ARCH=arm64
    fi
    step "macOS $version on ${ARCH:-$(uname -m)}"

    # Full Xcode, not only the Command Line Tools: the app is an Xcode project.
    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ "$developer_dir" != *.app/Contents/Developer ]]; then
        if [[ -d /Applications/Xcode.app ]]; then
            # Use Xcode for this run only, without changing the system-wide choice (that would need sudo).
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        else
            fail "Full Xcode is required, not only the Command Line Tools.
       Install Xcode from the App Store (https://apps.apple.com/app/xcode/id497799835),
       open it once to finish its setup, then run this again."
        fi
    fi
    xcodebuild -version >/dev/null 2>&1 || fail "xcodebuild does not run. Open Xcode once to finish its setup, or run:
       sudo xcodebuild -license accept && xcodebuild -runFirstLaunch"
    step "$(xcodebuild -version | head -1)"
}

# Sets `src` to the directory to build: this clone, or the cached checkout of the channel's branch, cloned or brought
# up to date first. It runs in the main shell, not in a command substitution where errexit is off, and every git step
# fails the install on its own, so a failed download never builds stale code.
prepare_source() {
    local here=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    fi
    if [[ -n "$here" && -d "$here/NotchLab.xcodeproj" && -x "$here/scripts/build.sh" ]]; then
        local current
        current="$(git -C "$here" branch --show-current 2>/dev/null || true)"
        step "Building this checkout${current:+ (branch $current)} as $app_name"
        src="$here"
        return
    fi
    src="$cache_root/$branch"
    check_cache_paths "$src"
    if [[ -e "$src" ]]; then
        owned_checkout "$src" || fail "$src was not created by this installer, so it is left alone.
       Move it away and run this again."
        step "Updating the $branch branch in $src"
        git -C "$src" remote set-url origin "$repo_url" || fail "Could not set the repository URL in $src."
        git -C "$src" fetch --quiet --depth 1 origin "$branch" || fail "Could not download the $branch branch from $repo_url."
        git -C "$src" reset --quiet --hard FETCH_HEAD || fail "Could not update $src."
        git -C "$src" clean --quiet -fdx -e .build || fail "Could not clean $src."
    else
        step "Downloading the $branch branch to $src"
        mkdir -p "$cache_root"
        git clone --quiet --depth 1 --branch "$branch" "$repo_url" "$src" \
            || fail "Could not download the $branch branch from $repo_url."
        echo "Cloned by Eclipse's install.sh; it updates and deletes this checkout." > "$src/.git/$owner_marker"
    fi
}

# Sets `dest`, where the app goes, and checks that it can be written without sudo, before anything is downloaded or
# built. An installed copy is updated where it is; a new one goes to /Applications when writable, else ~/Applications.
choose_destination() {
    dest="$(installed_path)"
    if [[ -n "$dest" ]]; then
        # swap_in refuses a link, so refuse it here, before the download and build.
        [[ ! -L "$dest" ]] || fail "$dest is a symbolic link. The installer only replaces a real app folder.
       Remove the link and run this again."
        # Ownership, not `-w` on the bundle: macOS briefly denies writes to an app it is checking right after launch.
        [[ -w "$(dirname "$dest")" && -O "$dest" ]] || fail "$app_name is installed at $dest, which this user cannot replace without admin rights.
       Delete it, or move it to a folder you can write to, then run this again."
        return
    fi
    if [[ ! -e "/Applications/$app_name.app" && -w /Applications ]]; then
        dest="/Applications/$app_name.app"
        return
    fi
    # A different app already uses the name in /Applications, or the folder is not writable without sudo.
    mkdir -p "$HOME/Applications" || fail "Could not create $HOME/Applications."
    [[ -w "$HOME/Applications" ]] || fail "$HOME/Applications is not writable."
    dest="$HOME/Applications/$app_name.app"
    [[ ! -e "$dest" ]] || fail "$dest belongs to another app. Move it away and run this again."
}

# Whether `dest` may be replaced: nothing is there, or this app is, owned by the user and not a symbolic link.
replaceable() {
    [[ ! -e "$dest" && ! -L "$dest" ]] && return 0
    [[ ! -L "$dest" && -d "$dest" && -O "$dest" && "$(bundle_id_of "$dest")" == "$bundle_id" ]]
}

# Renames `from` to `to`, which must not exist. macOS `mv` would move `from` into a folder that appeared at `to`
# instead of failing, so the result is checked too.
rename_to() {
    local from="$1" to="$2"
    [[ ! -e "$to" && ! -L "$to" ]] || return 1
    mv -n "$from" "$to" || return 1
    [[ -e "$to" && ! -e "$from" && ! -e "$to/$(basename "$from")" ]]
}

# Puts the staged build at `dest`. While the old copy is set aside in the staging folder (`backup`), any failure or
# interruption ends in `finish`, which puts it back.
swap_in() {
    replaceable || fail "$dest changed during the build and is not $app_name any more. Nothing was replaced."
    quit_app
    replaceable || fail "$dest changed while $app_name was quitting. Nothing was replaced."
    if [[ -e "$dest" ]]; then
        backup="$stage/previous.app"
        rename_to "$dest" "$backup" || fail "Could not move the installed $app_name aside."
    fi
    rename_to "$stage/$app_name.app" "$dest" || fail "Could not install to $dest; something else is there now."
    backup=""
}

# Runs on every exit. An old copy still set aside goes back to `dest` if that is free; otherwise it is kept and its
# path printed. The staging folder is deleted only when nothing in it is needed any more.
finish() {
    if [[ -n "$backup" && -e "$backup" ]]; then
        if rename_to "$backup" "$dest"; then
            echo "The previous $app_name was put back at $dest." >&2
        else
            echo "The previous $app_name is kept at $backup. Move it back to $dest yourself." >&2
            return
        fi
    fi
    rm -rf "$stage"
}

install() {
    check_system
    choose_destination
    prepare_source
    step "Building $app_name (the first build takes a few minutes)"
    "$src/scripts/build.sh" "${build_flags[@]+"${build_flags[@]}"}" </dev/null >/dev/null \
        || fail "The build failed. The full log is $src/.build/build.log"
    local built="$src/.build/$derived_data/Build/Products/Release/$app_name.app"
    [[ -d "$built" ]] || fail "The build finished but $built is missing."

    # Stage the new copy next to the destination before quitting anything, so a failed copy leaves the running app
    # alone. `stage` and `backup` are global, so `finish` still sees them after this function returns.
    stage="$(mktemp -d "$(dirname "$dest")/.eclipse-install.XXXXXX")" || fail "Could not write to $(dirname "$dest")."
    backup=""
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    ditto "$built" "$stage/$app_name.app" || fail "Could not copy $app_name to $(dirname "$dest")."
    swap_in
    step "Installed $dest"

    open "$dest"
    step "Opened $app_name"
    if [[ -n "${ECLIPSE_CODESIGN_IDENTITY:-}" ]]; then
        cat <<EOF

The app is signed with "$ECLIPSE_CODESIGN_IDENTITY". macOS keeps its permissions
across updates signed with the same certificate.
Run the same command again to update.
EOF
    else
        cat <<EOF

The app is built on this Mac and signed ad hoc, without an Apple Developer ID.
macOS sees every update as a new app, so allow its permissions again after an
update, or sign it with your own certificate (see "Keep permissions across
updates" in the README). Run the same command again to update.
EOF
    fi
}

if [[ "$action" == uninstall ]]; then uninstall; else install; fi
