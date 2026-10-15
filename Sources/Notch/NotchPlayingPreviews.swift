import AppKit
import SwiftUI

/// The wave in a small closed-notch stand-in on the Now Playing settings page. It rests until Preview plays it for a
/// few seconds, so the page never animates on its own. Turning the wave off, leaving the page or the window going out
/// of sight ends a preview at once.
struct NotchWavePreview: View {
    let style: NotchWaveStyle
    let color: Color
    /// The wave is on and the window can be seen.
    let active: Bool
    @State private var run = 0
    /// The Preview press playing now, nil at rest.
    @State private var playing: Int?

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 4).fill(NotchPreviewArt.gradient(0)).frame(width: 22, height: 22)
                    .frame(width: 40)
                Spacer(minLength: 0)
                NotchWaveView(style: style, color: color, moving: playing != nil, visible: active)
                    .frame(width: 40)
            }
            .frame(width: 160, height: 32)
            .background(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black))
            Spacer()
            Button("Preview") { run += 1 }.buttonStyle(NotchButtonStyle())
        }
        .padding(.horizontal, 16).frame(height: 56)
        .task(id: run) {
            guard run > 0, active else { return }
            let current = run
            playing = current
            try? await Task.sleep(for: .seconds(4))
            // A newer press owns the preview; a cancelled or finished one only ends its own.
            if playing == current { playing = nil }
        }
        .onChange(of: active) { _, active in
            if !active { playing = nil }
        }
        .onDisappear { playing = nil }
    }
}

/// The player's artwork at its open size on the Now Playing settings page; Preview turns it once to the other of two
/// stand-in images, alternately as next and as previous, so a slide shows both ways.
struct NotchArtworkPreview: View {
    let transition: NotchArtworkTransition
    let openDuration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var artwork = NotchShownArtwork(image: NotchPreviewArt.image(0))

    var body: some View {
        HStack(spacing: 14) {
            NotchArtworkSwap(artwork: artwork, size: 52)
                .environment(\.notchArtworkMotion, motion)
            Spacer()
            Button("Preview", action: turn).buttonStyle(NotchButtonStyle())
        }
        .padding(.horizontal, 16).frame(height: 76)
    }

    private var motion: NotchArtworkMotion {
        guard transition != .none else { return NotchArtworkMotion() }
        return NotchArtworkMotion(transition: transition, reduceMotion: reduceMotion,
                                  animation: .spring(duration: openDuration * 1.2, bounce: 0))
    }

    private func turn() {
        let number = artwork.turn.number + 1
        artwork = NotchShownArtwork(image: NotchPreviewArt.image(number % 2),
                                    turn: .init(number: number, direction: number % 2 == 1 ? .next : .previous))
    }
}

/// Two gradient squares standing in for album art in the settings previews.
private enum NotchPreviewArt {
    static let colors: [(NSColor, NSColor)] = [
        (NSColor(srgbRed: 0.31, green: 0.78, blue: 0.82, alpha: 1), NSColor(srgbRed: 0.22, green: 0.2, blue: 0.62, alpha: 1)),
        (NSColor(srgbRed: 0.98, green: 0.6, blue: 0.3, alpha: 1), NSColor(srgbRed: 0.72, green: 0.16, blue: 0.42, alpha: 1))
    ]

    static func gradient(_ index: Int) -> LinearGradient {
        LinearGradient(colors: [Color(nsColor: colors[index].0), Color(nsColor: colors[index].1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private static let images: [NSImage] = colors.map { pair in
        NSImage(size: NSSize(width: 104, height: 104), flipped: false) { rect in
            NSGradient(starting: pair.0, ending: pair.1)?.draw(in: rect, angle: -45)
            return true
        }
    }

    static func image(_ index: Int) -> NSImage { images[index] }
}
