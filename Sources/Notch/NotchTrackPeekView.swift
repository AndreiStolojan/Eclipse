import AppKit
import SwiftUI

/// The mini peek on a track change: the closed notch drops one slim row with the artwork, the title and the
/// artist or website. A newer track crossfades in place; a title too long for the row glides to its end and back
/// while the peek shows. A click opens the player.
struct NotchTrackPeekView: View {
    let peek: NotchTrackPeek
    @ObservedObject var experience: NotchExperience
    let topHeight: CGFloat
    /// Text and artwork crossfading to a newer track; nil in still renders.
    let crossfade: Animation?

    var body: some View {
        Button { experience.open() } label: {
            ZStack {
                // Built here, so the outgoing row keeps its own artwork while the next one fades in.
                row(artwork: experience.trackPeekArtwork).id(peek).transition(.opacity)
            }
            .animation(crossfade, value: peek)
            .padding(.leading, 14).padding(.trailing, 14)
            .frame(height: NotchGeometry.trackPeekDrop - 4)
            .padding(.top, topHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchRowPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(["Now playing", peek.title, peek.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAction { experience.open() }
    }

    private func row(artwork: NSImage?) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if peek.siteTile {
                    NotchSiteTile(icon: artwork, size: 24)
                } else if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: "music.note").font(.system(size: 11))
                        .frame(width: 24, height: 24).background(.white.opacity(0.12))
                }
            }
            .frame(width: 24, height: 24).notchArtworkTile(cornerRadius: 5)
            .animation(crossfade, value: artwork != nil)
            VStack(alignment: .leading, spacing: 0) {
                NotchMarquee(text: peek.title, font: .system(size: 11.5, weight: .semibold), read: experience.readTrackPeek)
                if let detail = peek.detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: detail.readsRightToLeft ? .trailing : .leading)
                }
            }
        }
    }
}

/// One line that fits, or that rests, glides to reveal its end, rests and glides back, as Apple Music's titles do,
/// with soft edges where text runs on. It moves only while on screen and rests between glides, so nothing repaints
/// then; under Reduce Motion it truncates with an ellipsis instead. Right-to-left text starts at the right and glides
/// the other way.
private struct NotchMarquee: View {
    let text: String
    let font: Font
    /// Told how many seconds from now the first reveal needs, so the peek can stay for it.
    let read: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var moved = false

    /// Seconds at each end, the glide's speed in points per second and the width of the soft edges.
    private static let rest: Double = 1.4
    private static let speed: Double = 32
    private static let fade: CGFloat = 10

    var body: some View {
        let rightToLeft = text.readsRightToLeft
        let alignment: Alignment = rightToLeft ? .trailing : .leading
        let overflow = max(0, textWidth - boxWidth)
        let scrolls = overflow > 1 && !reduceMotion
        Text(text).font(font).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: alignment)
            .opacity(scrolls ? 0 : 1)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: alignment) {
                if scrolls {
                    Text(text).font(font).fixedSize()
                        .offset(x: rightToLeft ? offset : -offset)
                        .frame(width: boxWidth, alignment: alignment)
                        .mask(edges(rightToLeft: rightToLeft))
                        .accessibilityHidden(true)
                }
            }
            .task(id: scrolls ? overflow : 0) { await glide(overflow: scrolls ? overflow : 0) }
    }

    /// The far edge always fades where text runs on; the near one only once the text has moved away from it.
    private func edges(rightToLeft: Bool) -> some View {
        let near = moved ? Self.fade : 0
        return HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: rightToLeft ? Self.fade : near)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: rightToLeft ? near : Self.fade)
        }
    }

    /// Rests, glides until the end clears the far fade, rests and glides back, until the view leaves and the task is
    /// cancelled with it.
    private func glide(overflow: CGFloat) async {
        offset = 0
        moved = false
        guard overflow > 0 else { return }
        let distance = overflow + Self.fade
        let reveal = max(1, Double(distance) / Self.speed)
        read(Self.rest + reveal + Self.rest)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.rest))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: reveal)) { offset = distance; moved = true }
            try? await Task.sleep(for: .seconds(reveal + Self.rest))
            guard !Task.isCancelled else { return }
            withAnimation(.spring(duration: 0.9, bounce: 0)) { offset = 0; moved = false }
            try? await Task.sleep(for: .seconds(0.9))
        }
    }
}
