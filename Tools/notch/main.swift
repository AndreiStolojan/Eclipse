// notch: posts one notice to Eclipse's local socket. Built with Sources/Notch/NotchMessage.swift by
// scripts/build.sh into .build/notch. Exit codes: 0 sent, 1 Eclipse not reachable, 2 invalid input.
import Foundation

let usage = """
    usage: notch [--symbol NAME] [--tint COLOUR] [--id ID] [--progress 0...1] [--socket PATH] [--] TITLE [DETAIL]
           notch --stdin [--socket PATH]
    tints: \(NotchTint.allCases.map(\.rawValue).joined(separator: " "))
    """

/// Prints to stderr and exits.
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
    exit(code)
}

var positional: [String] = []
var options: [String: String] = [:]
var stdinMode = false
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--":
        positional += arguments
        arguments = []
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--stdin":
        guard !stdinMode else { fail("--stdin specified twice", code: 2) }
        stdinMode = true
    case "--symbol", "--tint", "--id", "--progress", "--socket":
        guard let value = arguments.popFirst() else { fail("\(argument) needs a value\n\(usage)", code: 2) }
        options[String(argument.dropFirst(2))] = value
    case _ where argument.hasPrefix("--"):
        fail("unknown option \(argument)\n\(usage)", code: 2)
    default:
        positional.append(argument)
    }
}
if stdinMode {
    guard positional.isEmpty, options.keys.allSatisfy({ $0 == "socket" }) else {
        fail("--stdin accepts only --socket", code: 2)
    }
} else {
    guard (1...2).contains(positional.count) else { fail(usage, code: 2) }
}

var progress: Double?
if let raw = options["progress"] {
    guard let value = Double(raw) else { fail("invalid progress", code: 2) }
    progress = value
}
let notice: NotchNotice
let validated: Result<NotchNotice, NotchRejection>
if stdinMode {
    var input = Data()
    do {
        while let chunk = try FileHandle.standardInput.read(upToCount: NotchMessage.maxLine + 1 - input.count),
              !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= NotchMessage.maxLine else { fail(NotchRejection.oversized.description, code: 2) }
        }
    } catch {
        fail("could not read stdin", code: 2)
    }
    validated = NotchMessage.parseNoticeInput(input)
} else {
    validated = NotchNotice.validated(title: positional[0], detail: positional.count > 1 ? positional[1] : nil,
                                    symbol: options["symbol"], tint: options["tint"], id: options["id"], progress: progress)
}
switch validated {
case .success(let valid): notice = valid
case .failure(let reason): fail(reason.description, code: 2)
}
// Text is limited in characters, and one character can hold many scalars, so the encoded line is measured too; the
// app refuses anything longer. The re-encoded stdin line can also differ in size from what was read.
let line = NotchMessage.notify(notice).line
guard line.count <= NotchMessage.maxLine else { fail(NotchRejection.oversized.description, code: 2) }

let path = options["socket"] ?? NotchUnixSocket.defaultPath
guard let fd = NotchUnixSocket.connect(to: path) else {
    fail("Eclipse is not listening at \(path) (\(String(cString: strerror(errno))))", code: 1)
}
let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
close(fd)
guard written == line.count else { fail("write failed (\(String(cString: strerror(errno))))", code: 1) }
