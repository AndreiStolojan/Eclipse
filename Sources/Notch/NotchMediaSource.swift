import AppKit
import MediaRemoteAdapter

/// Uses player identity, never a video title, to label the app supplying media.
struct NotchMediaSource {
    let name: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let isBrowser: Bool

    init(_ track: TrackInfo.Payload) {
        let reportedName = track.applicationName ?? "System player"
        let reportedBundle = track.bundleIdentifier
        if reportedBundle == "com.spotify.client" || reportedName == "Spotify" {
            name = "Spotify"
            bundleIdentifier = "com.spotify.client"
            isBrowser = false
        } else if reportedBundle == "com.apple.Safari" || reportedName == "Safari" || reportedName == "Safari Graphics and Media" {
            name = "Safari"
            bundleIdentifier = "com.apple.Safari"
            isBrowser = true
        } else if reportedBundle == "com.apple.Music" || reportedName == "Music" {
            name = "Apple Music"
            bundleIdentifier = "com.apple.Music"
            isBrowser = false
        } else {
            name = reportedName
            bundleIdentifier = reportedBundle
            isBrowser = reportedBundle.map(NotchWebSites.browsers.contains) ?? false
        }
        if let bundleIdentifier, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = nil
        }
    }
}
