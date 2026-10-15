import Foundation

// The socket's wire format, shared by the app and the `notch` CLI (Tools/notch), so this file stays Foundation only.
// One JSON object per line, UTF-8, at most `NotchMessage.maxLine` bytes including the newline. See docs/socket.md.

/// The colours a notice may ask for; anything else is rejected rather than guessed.
enum NotchTint: String, CaseIterable, Sendable {
    case white, green, red, orange, yellow, blue, teal, purple, pink
}

/// A notification for the closed notch, already sanitised: plain single-line text within the length limits, a
/// symbol name that looks like an SF Symbol, progress within 0...1. A notice with the same `id` as the one showing
/// replaces it.
struct NotchNotice: Equatable, Sendable {
    let title: String
    let detail: String?
    let symbol: String?
    let tint: NotchTint
    let id: String?
    let progress: Double?

    static let titleLimit = 40
    static let detailLimit = 80

    /// Validates raw fields as they arrive from JSON or the command line. Text is cleaned and truncated; a field that
    /// cannot be cleaned (a malformed symbol, an unknown tint, a non-finite progress) rejects the whole notice.
    static func validated(title: String?, detail: String? = nil, symbol: String? = nil, tint: String? = nil,
                          id: String? = nil, progress: Double? = nil) -> Result<NotchNotice, NotchRejection> {
        guard let title else { return .failure(.missing("title")) }
        guard let cleanTitle = NotchText.clean(title, limit: titleLimit) else { return .failure(.invalid("title")) }
        if let symbol, !NotchText.isSymbolName(symbol) { return .failure(.invalid("symbol")) }
        var parsedTint = NotchTint.white
        if let tint {
            guard let known = NotchTint(rawValue: tint) else { return .failure(.invalid("tint")) }
            parsedTint = known
        }
        if let id, !NotchText.isIdentifier(id) { return .failure(.invalid("id")) }
        if let progress, !progress.isFinite { return .failure(.invalid("progress")) }
        return .success(NotchNotice(title: cleanTitle, detail: detail.flatMap { NotchText.clean($0, limit: detailLimit) },
                                    symbol: symbol, tint: parsedTint, id: id, progress: progress.map { min(max($0, 0), 1) }))
    }
}

/// What the dictation client (Sotto) is doing.
enum NotchDictationState: String, Sendable {
    case idle, starting, recording, processing
}

/// One dictation report: the state and the input level, 0...1.
struct NotchDictationUpdate: Equatable, Sendable {
    let state: NotchDictationState
    let level: Double
}

/// Why a line was refused. The descriptions name fields, never their content, so they are safe to log and print.
enum NotchRejection: Error, Equatable, Sendable, CustomStringConvertible {
    case oversized, invalidUTF8, malformed, unknownType
    case missing(String)
    case invalid(String)

    var description: String {
        switch self {
        case .oversized: "line longer than \(NotchMessage.maxLine) bytes"
        case .invalidUTF8: "not UTF-8"
        case .malformed: "not a JSON object"
        case .unknownType: "unknown type"
        case .missing(let field): "missing \(field)"
        case .invalid(let field): "invalid \(field)"
        }
    }
}

/// A message from a client to the notch.
enum NotchMessage: Equatable, Sendable {
    case notify(NotchNotice)
    case dictation(NotchDictationUpdate)

    /// The longest accepted line in bytes, including its newline.
    static let maxLine = 4096

    /// Every field any message type uses; the decoder checks JSON types, `parse` checks the values.
    private struct Wire: Codable {
        var type: String
        var title, detail, symbol, tint, id: String?
        var progress: Double?
        var state: String?
        var level: Double?
    }

    /// Parses one line without its newline. Unknown keys are ignored so clients can add fields ahead of the app.
    static func parse(_ line: Data) -> Result<NotchMessage, NotchRejection> {
        guard line.count < maxLine else { return .failure(.oversized) }
        guard String(data: line, encoding: .utf8) != nil else { return .failure(.invalidUTF8) }
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: line)
        } catch DecodingError.keyNotFound(let key, _) {
            return .failure(.missing(key.stringValue))
        } catch DecodingError.typeMismatch(_, let context) where !context.codingPath.isEmpty {
            return .failure(.invalid(context.codingPath[0].stringValue))
        } catch {
            return .failure(.malformed)
        }
        switch wire.type {
        case "notify":
            return NotchNotice.validated(title: wire.title, detail: wire.detail, symbol: wire.symbol, tint: wire.tint,
                                         id: wire.id, progress: wire.progress).map(NotchMessage.notify)
        case "dictation":
            guard let raw = wire.state else { return .failure(.missing("state")) }
            guard let state = NotchDictationState(rawValue: raw) else { return .failure(.invalid("state")) }
            let level = wire.level ?? 0
            guard level.isFinite else { return .failure(.invalid("level")) }
            return .success(.dictation(NotchDictationUpdate(state: state, level: min(max(level, 0), 1))))
        default:
            return .failure(.unknownType)
        }
    }

    /// The message as one line ready to write, newline included; absent optional fields are left out.
    var line: Data {
        let wire = switch self {
        case .notify(let notice):
            Wire(type: "notify", title: notice.title, detail: notice.detail, symbol: notice.symbol,
                 tint: notice.tint.rawValue, id: notice.id, progress: notice.progress)
        case .dictation(let update):
            Wire(type: "dictation", state: update.state.rawValue, level: update.level)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Encoding plain strings and finite numbers cannot fail.
        return ((try? encoder.encode(wire)) ?? Data()) + Data("\n".utf8)
    }
}

/// A message from the notch to the dictation client.
enum NotchReply: Equatable, Sendable {
    /// Whether the notch currently shows dictation, so the client can hide its own indicator.
    case presenting(available: Bool)
    /// The user clicked stop: finish the recording and insert the text.
    case stop
    /// Discard the recording.
    case cancel

    /// The reply as one line, newline included.
    var line: Data {
        let json = switch self {
        case .presenting(let available): #"{"type":"presenting","available":\#(available)}"#
        case .stop: #"{"type":"stop"}"#
        case .cancel: #"{"type":"cancel"}"#
        }
        return Data((json + "\n").utf8)
    }
}

/// A token bucket per connection: bursts of up to 60 lines, 60 lines per second sustained. Sotto's 20 Hz levels pass;
/// a flood is cut to the sustained rate and the excess dropped.
struct NotchRateLimit: Sendable {
    static let capacity = 60.0
    static let perSecond = 60.0
    private var tokens = capacity
    private var last: UInt64?

    /// Whether a line arriving at `now` (monotonic nanoseconds) may pass; spends a token when it does.
    mutating func allow(at now: UInt64) -> Bool {
        if let last { tokens = min(Self.capacity, tokens + Double(now &- last) / 1e9 * Self.perSecond) }
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Text rules for notices.
enum NotchText {
    /// Single-line plain text: line breaks and tabs become spaces, other control and bidirectional formatting
    /// characters are dropped (no spoofed reading order), the ends are trimmed and anything past `limit` characters
    /// is cut with an ellipsis. Nil when nothing is left.
    static func clean(_ text: String, limit: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: scalars.append(" ")
            case .control: if properties.isWhitespace { scalars.append(" ") }
            default: if !properties.isBidiControl { scalars.append(scalar) }
            }
        }
        var result = String(scalars).trimmingCharacters(in: .whitespaces)
        if result.count > limit {
            result = result.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
        }
        return result.isEmpty ? nil : result
    }

    /// `^[a-z0-9]+(\.[a-z0-9]+)*$`, at most 64 characters: the shape of SF Symbol names.
    static func isSymbolName(_ name: String) -> Bool {
        name.utf8.count <= 64 && name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) }
        }
    }

    /// 1 to 64 characters of `[A-Za-z0-9._-]`.
    static func isIdentifier(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy { byte in
            (0x61...0x7A).contains(byte) || (0x41...0x5A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}

/// Unix domain socket plumbing shared by the server and the CLI.
enum NotchUnixSocket {
    /// Where the app listens and the CLI connects by default. The folder keeps the Notch Lab name because Sotto connects here.
    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Notch Lab/notch.sock").path

    /// A socket address for `path`, or nil when the path does not fit (about 103 bytes).
    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A new stream socket, set up by `configure`.
    static func makeSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        return fd
    }

    /// Close-on-exec, so launched processes do not inherit it, and no SIGPIPE when writing to a closed peer: the
    /// write fails with EPIPE instead of killing the process.
    static func configure(_ fd: Int32) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    /// Connects a new blocking socket to `path`. Returns the descriptor, or nil with `errno` describing the failure.
    static func connect(to path: String) -> Int32? {
        guard var address = address(path) else { errno = ENAMETOOLONG; return nil }
        guard let fd = makeSocket() else { return nil }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let error = errno
            close(fd)
            errno = error
            return nil
        }
        return fd
    }
}
