import AppKit
import SwiftUI

/// The style and spring of the artwork's turns, set once for the notch. Without an animation images change at once.
struct NotchArtworkMotion {
    var transition = NotchArtworkTransition.none
    var reduceMotion = false
    var animation: Animation?
}

extension EnvironmentValues {
    @Entry var notchArtworkMotion = NotchArtworkMotion()
}

/// Artwork that turns to each new image, in the style from the environment. At most two faces are mounted, the
/// old under the new. A newer image arriving mid-turn replaces the incoming face in place and the turn runs on, so
/// rapid skips never stack views or restart the motion; the old face goes once the turn has come to rest. The style
/// and direction are kept from the start of a turn. A newly mounted view shows the current image without a turn. When
/// the motion stops, the notch hidden, locked or out of sight, a turn under way settles at once on the new face.
struct NotchArtworkSwap: View {
    let artwork: NotchShownArtwork
    let size: CGFloat
    @Environment(\.notchArtworkMotion) private var motion
    @State private var front: Face?
    @State private var back: Face?
    /// Turns started; `step` follows it on the spring, and the gap between them is how far the turn has come.
    @State private var target: Double = 0
    @State private var step: Double = 0
    @State private var turning = false
    @State private var style = NotchArtworkTransition.none
    @State private var direction = NotchSkipDirection.next
    /// Changes when a turn is settled early, remounting the faces so its spring stops with them.
    @State private var generation = 0

    private struct Face {
        let turn: Int
        let image: NSImage?
    }

    var body: some View {
        let shown = front ?? Face(turn: artwork.turn.number, image: artwork.image)
        // Everything but a flip stays inside the tile; a flip leans out of it.
        let clipped = style != .flip
        ZStack {
            if let back {
                face(back).modifier(pose(outgoing: true)).transition(.identity)
            }
            face(shown).modifier(pose(outgoing: false))
        }
        .id(generation)
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous).inset(by: clipped ? 0 : -size))
        .onChange(of: motion.animation == nil) { _, still in
            if still { settle() }
        }
        .onChange(of: artwork) { old, new in
            guard new.turn != old.turn else { return }
            turn(to: Face(turn: new.turn.number, image: new.image), from: Face(turn: old.turn.number, image: old.image),
                 direction: new.turn.direction)
        }
        .accessibilityHidden(true)
    }

    /// Starts a turn from the face shown to `face`, or swaps the incoming face of a turn under way.
    private func turn(to face: Face, from previous: Face, direction: NotchSkipDirection) {
        guard let animation = motion.animation, motion.transition != .none else {
            front = face
            back = nil
            return
        }
        if turning {
            front = face
            return
        }
        back = front ?? previous
        front = face
        style = motion.transition
        self.direction = direction
        turning = true
        target += 1
        let started = generation
        withAnimation(animation, completionCriteria: .removed) {
            step = target
        } completion: {
            guard generation == started else { return }
            turning = false
            back = nil
        }
    }

    /// Ends a turn under way on the new face without its spring.
    private func settle() {
        guard turning else { return }
        turning = false
        back = nil
        generation += 1
    }

    private func pose(outgoing: Bool) -> NotchArtworkTurnEffect {
        NotchArtworkTurnEffect(step: step, target: target, style: style, direction: direction, outgoing: outgoing,
                               reduceMotion: motion.reduceMotion, size: size)
    }

    /// The image filling the square tile, or a note on an opaque tile, so a face never lets the one beneath through.
    /// The edge turns with the face.
    private func face(_ face: Face) -> some View {
        Group {
            if let image = face.image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: size * 0.45))
                    .frame(width: size, height: size).background(.white.opacity(0.12)).background(.black)
            }
        }
        .frame(width: size, height: size)
        .notchArtworkTile(cornerRadius: size * 0.18)
    }
}

extension View {
    /// Clips artwork, already filling its square frame, to the rounded tile and draws a faint hairline edge on it, so
    /// a cover as dark as the notch still reads as its whole square rather than as the lighter shapes on it.
    func notchArtworkTile(cornerRadius: CGFloat) -> some View {
        let tile = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(tile).overlay(tile.strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }
}

/// Places a face by the turn's progress, read from the spring-driven `step` against `target`.
private struct NotchArtworkTurnEffect: ViewModifier, Animatable {
    var step: Double
    let target: Double
    let style: NotchArtworkTransition
    let direction: NotchSkipDirection
    let outgoing: Bool
    let reduceMotion: Bool
    let size: CGFloat

    var animatableData: Double {
        get { step }
        set { step = newValue }
    }

    func body(content: Content) -> some View {
        let pose = NotchArtworkPose(style, progress: 1 - (target - step), direction: direction, outgoing: outgoing,
                                    reduceMotion: reduceMotion)
        content
            .blur(radius: pose.blur * size)
            .scaleEffect(pose.scale)
            .rotation3DEffect(.degrees(pose.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .offset(x: pose.offset * size)
            .opacity(pose.opacity)
    }
}
