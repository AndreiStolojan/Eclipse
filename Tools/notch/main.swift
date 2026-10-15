// notch: posts one notice to Eclipse's local socket. Built with Sources/Notch/NotchMessage.swift by
// scripts/build.sh into .build/notch. Exit codes: 0 sent, 1 Eclipse not reachable, 2 invalid input.
import Foundation

let usage = """
    usage: notch [--symbol NAME] [--tint COLOUR] [--id ID] [--progress 0...1] [--socket PATH] [--] TITLE [DETAIL]
    tints: \(NotchTint.allCases.map(\.rawValue).joined(separator: " "))
    """

/// Prints to stderr and exits.
func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("notch: \(message)\n".utf8))
    exit(code)
}

var positional: [String] = []
var options: [String: String] = [:]
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--":
        positional += arguments
        arguments = []
    case "-h", "--help":
        print(usage)
        exit(0)
    case "--symbol", "--tint", "--id", "--progress", "--socket":
        guard let value = arguments.popFirst() else { fail("\(argument) needs a value\n\(usage)", code: 2) }
        options[String(argument.dropFirst(2))] = value
    case _ where argument.hasPrefix("--"):
        fail("unknown option \(argument)\n\(usage)", code: 2)
    default:
        positional.append(argument)
    }
}
guard (1...2).contains(positional.count) else { fail(usage, code: 2) }

var progress: Double?
if let raw = options["progress"] {
    guard let value = Double(raw) else { fail("invalid progress", code: 2) }
    progress = value
}
let notice: NotchNotice
switch NotchNotice.validated(title: positional[0], detail: positional.count > 1 ? positional[1] : nil,
                             symbol: options["symbol"], tint: options["tint"], id: options["id"], progress: progress) {
case .success(let valid): notice = valid
case .failure(let reason): fail(reason.description, code: 2)
}

let path = options["socket"] ?? NotchUnixSocket.defaultPath
guard let fd = NotchUnixSocket.connect(to: path) else {
    fail("Eclipse is not listening at \(path) (\(String(cString: strerror(errno))))", code: 1)
}
let line = NotchMessage.notify(notice).line
let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
close(fd)
guard written == line.count else { fail("write failed (\(String(cString: strerror(errno))))", code: 1) }
