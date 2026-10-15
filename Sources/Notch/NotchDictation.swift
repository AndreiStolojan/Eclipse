import Combine
import Foundation

/// The dictation client as the notch sees it: Sotto reports state and input level over the socket, the notch answers
/// with stop, cancel and whether it is presenting. Only one client at a time; the connection that most recently sent
/// a dictation message is it. NotchSocket links the client in with `attach` and out with `detach`.
@MainActor
final class NotchDictation: ObservableObject {
    @Published private(set) var state: NotchDictationState = .idle
    /// Input level, 0...1, at whatever rate the client sends it (Sotto: 20 Hz while recording).
    @Published private(set) var level: Double = 0
    /// Whether a dictation client is connected.
    @Published private(set) var connected = false
    /// Called after a state change; level updates do not call it.
    var onChange: ((NotchDictationState) -> Void)?
    /// Whether the notch shows dictation now. The client is told on every change, and on attaching.
    var presenting = false {
        didSet { if presenting != oldValue { send?(.presenting(available: presenting)) } }
    }
    /// Writes to the current client; nil while none is attached.
    private var send: ((NotchReply) -> Void)?

    /// Asks the client to finish the recording and insert the text.
    func stop() { send?(.stop) }

    /// Asks the client to discard the recording.
    func cancel() { send?(.cancel) }

    /// Makes `send` the way to the client, replacing any previous one, and tells it whether the notch presents.
    func attach(_ send: @escaping (NotchReply) -> Void) {
        self.send = send
        connected = true
        send(.presenting(available: presenting))
    }

    func update(_ update: NotchDictationUpdate) {
        level = update.level
        setState(update.state)
    }

    /// The client went away: back to idle and disconnected.
    func detach() {
        send = nil
        connected = false
        level = 0
        setState(.idle)
    }

    private func setState(_ new: NotchDictationState) {
        guard state != new else { return }
        state = new
        onChange?(new)
    }
}
