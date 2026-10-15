import AppKit
import SwiftUI

/// The Playlist slot: a list with a plus. A press opens the playlists the current track can join, the recently used
/// first, and picking one adds the track; the symbol turns into a checkmark in the accent colour, or a cross when the
/// add failed, for a moment. Dimmed for players without playlists Eclipse can reach. The notch stays open while the
/// menu is up.
struct NotchPlaylistButton: View {
    let experience: NotchExperience
    @ObservedObject var playlists: NotchPlaylists
    let request: NotchLikeRequest?
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let enabled = request.map { NotchPlaylists.supports($0.target) } ?? false
        let outcome = playlists.ledger.outcome.flatMap { $0.request == request ? $0 : nil }
        Button(action: press) {
            Image(systemName: outcome.map { $0.added ? "checkmark" : "xmark" } ?? "text.badge.plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(outcome?.added == true ? accent : .white.opacity(enabled ? 0.4 : 0.15))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.up, options: .nonRepeating, value: reduceMotion ? 0 : outcome?.serial ?? 0)
                .frame(width: 36, height: 36).contentShape(Rectangle())
                .animation(.spring(duration: 0.35, bounce: 0), value: outcome)
        }
        .buttonStyle(NotchPressStyle())
        .disabled(!enabled)
        .accessibilityLabel("Add to playlist")
        .accessibilityValue(outcome.map { $0.added ? "Added" : "Not added" } ?? (enabled ? "" : "Unavailable"))
        .help(enabled ? "Add to playlist" : "Playlists are available for Apple Music and Spotify")
    }

    private func press() {
        Task { @MainActor in
            guard let menu = await playlists.menu() else { return }
            let items = NSMenu()
            for group in [menu.recent, menu.rest] where !group.isEmpty {
                if !items.items.isEmpty { items.addItem(.separator()) }
                for playlist in group {
                    let item = NSMenuItem(title: playlist.name, action: #selector(NotchMenuAction.run), keyEquivalent: "")
                    let action = NotchMenuAction { [playlists] in playlists.add(playlist, for: menu.request) }
                    item.target = action
                    // The item's target is weak; the represented object keeps the action alive as long as the menu.
                    item.representedObject = action
                    items.addItem(item)
                }
            }
            if items.items.isEmpty {
                let empty = NSMenuItem(title: "No playlists", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                items.addItem(empty)
            }
            experience.holdOpen { items.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }
        }
    }
}
