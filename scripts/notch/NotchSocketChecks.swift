import AppKit
import Foundation

/// Tests the real socket in a disposable folder, including the opt-in boundary between notices and dictation.
@main
struct NotchSocketChecks {
    @MainActor
    static func main() async throws {
        let folder = URL(fileURLWithPath: "/tmp").appending(path: "notch-\(UUID().uuidString)")
        let path = folder.appending(path: "n.sock").path
        let socket = NotchSocket(path: path)
        defer {
            socket.stop()
            try? FileManager.default.removeItem(at: folder)
        }
        var received: [NotchNotice] = []
        socket.onNotice = { received.append($0) }
        socket.start()
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: path) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let folderMode = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
        let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        precondition(folderMode?.intValue == 0o700 && socketMode?.intValue == 0o600, "Private folder and socket permissions")
        print("PASS Real socket uses a 0700 folder and 0600 socket")
        guard let fd = NotchUnixSocket.connect(to: path) else { fatalError("Test socket did not accept connection") }
        defer { close(fd) }
        func send(_ line: Data) {
            let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            precondition(written == line.count)
        }
        let notice = NotchNotice(title: "Backup failed", detail: nil, symbol: nil, tint: .red, id: "pi.backup", progress: nil)
        send(NotchMessage.notify(notice).line)
        try await Task.sleep(for: .milliseconds(100))
        precondition(received == [notice], "Validated notice callback")
        print("PASS Real socket delivers a validated notice from the same user")
        send(NotchMessage.dictation(NotchDictationUpdate(state: .recording, level: 0.5)).line)
        try await Task.sleep(for: .milliseconds(100))
        precondition(!socket.dictation.connected && socket.dictation.state == .idle, "Dictation disabled")
        print("PASS A notices-only socket ignores dictation")
        socket.acceptsDictation = true
        send(NotchMessage.dictation(NotchDictationUpdate(state: .recording, level: 0.5)).line)
        try await Task.sleep(for: .milliseconds(100))
        precondition(socket.dictation.connected && socket.dictation.state == .recording, "Dictation enabled")
        print("PASS Sotto opt-in permits dictation on the same socket")
        socket.acceptsDictation = false
        precondition(!socket.dictation.connected && socket.dictation.state == .idle, "Dictation detached")
        print("PASS Disabling Sotto detaches its state without disabling notices")
        send(NotchMessage.notify(notice).line)
        try await Task.sleep(for: .milliseconds(100))
        precondition(received == [notice, notice], "Notices remain enabled")
        print("PASS Notices still arrive after Sotto is disabled")
        socket.stop()
        precondition(!FileManager.default.fileExists(atPath: path), "Socket file cleaned")
        print("PASS Stopping removes the temporary socket")
        print("7 socket checks passed")
    }
}
