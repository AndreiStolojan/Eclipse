#!/bin/bash
# Focused placement and interaction checks; no microphone, media command, or permission mutation.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo_dir/.build/checks"
# Each check binary runs against a deadline, so one stuck waiting fails the run instead of blocking it. The slowest,
# the hover checks, sleep through about half a minute of real timers.
check_limit=180
run_check() {
    local status=0
    timeout -k 5 "$check_limit" "$@" || status=$?
    [[ $status -ne 124 ]] || echo "$(basename "$1") did not finish within $check_limit s" >&2
    return "$status"
}
swiftc "$repo_dir/Sources/Notch/NotchGeometry.swift" "$repo_dir/Sources/Notch/NotchSettings.swift" \
    "$repo_dir/Sources/Notch/NotchState.swift" "$repo_dir/Sources/Notch/NotchWebSource.swift" \
    "$repo_dir/Sources/Notch/NotchFocus.swift" "$repo_dir/Sources/Notch/NotchMediaKey.swift" \
    "$repo_dir/Sources/Notch/NotchBattery.swift" "$repo_dir/Sources/Notch/NotchTrackWatch.swift" \
    "$repo_dir/Sources/Notch/NotchScreenshots.swift" "$repo_dir/Sources/Notch/NotchDownloads.swift" "$repo_dir/Sources/Notch/NotchAgenda.swift" \
    "$repo_dir/Sources/Notch/NotchVisibility.swift" "$repo_dir/Sources/Notch/NotchAudioDevices.swift" \
    "$repo_dir/Sources/Notch/NotchAgents.swift" "$repo_dir/Sources/Notch/NotchMarkdown.swift" \
    "$repo_dir/Sources/Notch/NotchLike.swift" "$repo_dir/Sources/Notch/NotchTimer.swift" \
    "$repo_dir/Sources/Notch/NotchSpotify.swift" "$repo_dir/Sources/Notch/NotchBrowserLike.swift" \
    "$repo_dir/Sources/Notch/NotchWave.swift" "$repo_dir/Sources/Notch/NotchArtworkFlow.swift" \
    "$repo_dir/Sources/Notch/NotchSeek.swift" "$repo_dir/Sources/Notch/NotchWebPage.swift" \
    "$repo_dir/Sources/Notch/NotchBrowserTabs.swift" "$repo_dir/Sources/Notch/NotchSourcePick.swift" \
    "$repo_dir/scripts/notch/NotchCoreChecks.swift" \
    -o "$repo_dir/.build/checks/core-checks"
run_check "$repo_dir/.build/checks/core-checks"
swiftc "$repo_dir/Sources/Notch/NotchGeometry.swift" "$repo_dir/Sources/Notch/NotchSettings.swift" \
    "$repo_dir/Sources/Notch/NotchState.swift" "$repo_dir/Sources/Notch/NotchExperience.swift" \
    "$repo_dir/Sources/Notch/NotchShelf.swift" "$repo_dir/Sources/Notch/NotchClipboard.swift" "$repo_dir/Sources/Notch/NotchFocus.swift" "$repo_dir/Sources/Notch/NotchMediaKey.swift" \
    "$repo_dir/Sources/Notch/NotchScreenshots.swift" "$repo_dir/Sources/Notch/NotchDownloads.swift" "$repo_dir/Sources/Notch/NotchMessage.swift" "$repo_dir/Sources/Notch/NotchDictation.swift" \
    "$repo_dir/Sources/Notch/NotchAgenda.swift" "$repo_dir/Sources/Notch/NotchVisibility.swift" "$repo_dir/Sources/Notch/NotchAudioDevices.swift" \
    "$repo_dir/Sources/Notch/NotchAgents.swift" "$repo_dir/Sources/Notch/NotchMarkdown.swift" "$repo_dir/Sources/Notch/NotchT3.swift" \
    "$repo_dir/Sources/Notch/NotchTrackWatch.swift" "$repo_dir/Sources/Notch/NotchTimer.swift" \
    "$repo_dir/scripts/notch/NotchHoverChecks.swift" -o "$repo_dir/.build/checks/hover-checks"
run_check "$repo_dir/.build/checks/hover-checks"
# Spotify's sign in and Web API against a scripted server, the playlists and YouTube's like through Accessibility.
swiftc "$repo_dir/Sources/Notch/NotchLike.swift" "$repo_dir/Sources/Notch/NotchWebSource.swift" \
    "$repo_dir/Sources/Notch/NotchSpotify.swift" "$repo_dir/Sources/Notch/NotchBrowserLike.swift" \
    "$repo_dir/Sources/Notch/NotchPlaylist.swift" "$repo_dir/Sources/Notch/NotchBrowserTabs.swift" \
    "$repo_dir/Sources/Notch/NotchWebPage.swift" "$repo_dir/scripts/notch/NotchLikeChecks.swift" \
    -o "$repo_dir/.build/checks/like-checks"
run_check "$repo_dir/.build/checks/like-checks"
swiftc "$repo_dir/Sources/Notch/NotchAgents.swift" "$repo_dir/Sources/Notch/NotchMarkdown.swift" \
    "$repo_dir/scripts/notch/NotchAgentChecks.swift" \
    -o "$repo_dir/.build/checks/agent-checks"
run_check "$repo_dir/.build/checks/agent-checks"
swiftc "$repo_dir/Sources/Notch/NotchLockScreen.swift" "$repo_dir/scripts/notch/NotchLockChecks.swift" \
    -o "$repo_dir/.build/checks/lock-checks"
run_check "$repo_dir/.build/checks/lock-checks"
swiftc "$repo_dir/Sources/Notch/NotchClipboard.swift" "$repo_dir/scripts/notch/NotchClipboardChecks.swift" \
    -o "$repo_dir/.build/checks/clipboard-checks"
run_check "$repo_dir/.build/checks/clipboard-checks"
swiftc "$repo_dir/Sources/Notch/NotchMessage.swift" "$repo_dir/scripts/notch/NotchMessageChecks.swift" \
    -o "$repo_dir/.build/checks/message-checks"
run_check "$repo_dir/.build/checks/message-checks"
# The CLI shares the parser; compiling it here catches drift between the two.
swiftc "$repo_dir/Sources/Notch/NotchMessage.swift" "$repo_dir/Tools/notch/main.swift" -o "$repo_dir/.build/checks/notch"
swiftc "$repo_dir/Sources/Notch/NotchUpdate.swift" "$repo_dir/scripts/notch/NotchUpdateChecks.swift" \
    -o "$repo_dir/.build/checks/update-checks"
run_check "$repo_dir/.build/checks/update-checks"
