import AppKit
import Combine
import Foundation
import os

/// The local socket other programs post to: notices from scripts and the `notch` CLI, dictation state from Sotto.
/// Open only while the Sotto link is on.
/// A Unix domain socket in a private folder, accepting only processes of the same user; no network listener. IO runs
/// on a background queue, driven by dispatch sources, so nothing runs while the socket is idle; parsed messages hop
/// to the main actor. Protocol and security model: docs/socket.md.
@MainActor
final class NotchSocket: ObservableObject {
    /// The last notice received while running, nil until one arrives.
    @Published private(set) var notice: NotchNotice?
    /// Called after every notice, including one that repeats the current notice's `id`.
    var onNotice: ((NotchNotice) -> Void)?
    let dictation = NotchDictation()
    let path: String
    private let server: NotchSocketServer
    private var running = false
    /// The connection that most recently sent a dictation message.
    private var dictationClient: NotchSocketServer.ConnectionID?
    private var instancesCancellable: AnyCancellable?

    init(path: String = NotchUnixSocket.defaultPath) {
        self.path = path
        server = NotchSocketServer(path: path)
    }

    /// Opens the socket in the background. Failures are logged: another instance already listening, a folder owned
    /// by someone else, a path too long for a socket address.
    func start() {
        guard !running else { return }
        running = true
        listen()
        // An instance that found another one listening takes the socket over once that one quits. Eclipse is an
        // LSUIElement app, so only runningApplications reports its instances; launch and quit notifications do not.
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        instancesCancellable = NSWorkspace.shared.publisher(for: \.runningApplications)
            .map { apps in Set(apps.filter { $0.bundleIdentifier == bundleID }.map(\.processIdentifier)) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.listen() }
    }

    /// Starts listening unless this instance already does, so calling it again is harmless.
    private func listen() {
        guard running else { return }
        server.start { [weak self] event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event) } }
        }
    }

    /// Closes every connection and removes the socket file before returning.
    func stop() {
        guard running else { return }
        running = false
        instancesCancellable = nil
        server.stop()
        dictationClient = nil
        dictation.detach()
    }

    private func handle(_ event: NotchSocketServer.Event) {
        guard running else { return }
        switch event {
        case .message(_, .notify(let notice)):
            self.notice = notice
            onNotice?(notice)
        case .message(let id, .dictation(let update)):
            if dictationClient != id {
                dictationClient = id
                dictation.attach { [server] reply in server.send(reply.line, to: id) }
            }
            dictation.update(update)
        case .closed(let id):
            guard id == dictationClient else { return }
            dictationClient = nil
            dictation.detach()
        }
    }
}

/// The socket's IO half. Every property is touched only on `queue`, which is what makes it safe to share.
private final class NotchSocketServer: @unchecked Sendable {
    typealias ConnectionID = UInt64

    enum Event: Sendable {
        case message(ConnectionID, NotchMessage)
        case closed(ConnectionID)
    }

    /// One client: its descriptor, read source, bytes of an unfinished line and rate limit.
    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var limit = NotchRateLimit()
        var throttled = false

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    static let maxClients = 8
    private let path: String
    private let queue = DispatchQueue(label: "ro.andrei.NotchLab.socket")
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "socket")
    private var listener: DispatchSourceRead?
    private var connections: [ConnectionID: Connection] = [:]
    private var nextID: ConnectionID = 0
    private var handler: (@Sendable (Event) -> Void)?

    init(path: String) {
        self.path = path
    }

    func start(handler: @escaping @Sendable (Event) -> Void) {
        queue.async { [self] in
            guard listener == nil, let fd = listen() else { return }
            self.handler = handler
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
            log.notice("Listening on \(self.path, privacy: .public)")
        }
    }

    /// Synchronous, so the socket file is gone before the app exits. The queue never waits on the main thread,
    /// so this cannot deadlock.
    func stop() {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            connections.values.forEach { $0.source.cancel() }
            connections.removeAll()
            handler = nil
            unlink(path)
            log.notice("Stopped")
        }
    }

    /// Writes one line to a client. A client that cannot take a few dozen bytes at once is not reading, so it is
    /// closed rather than queued for.
    func send(_ line: Data, to id: ConnectionID) {
        queue.async { [self] in
            guard let connection = connections[id] else { return }
            let written = line.withUnsafeBytes { write(connection.fd, $0.baseAddress, $0.count) }
            if written != line.count {
                log.error("Closing client \(id): reply not written (\(String(cString: strerror(errno)), privacy: .public))")
                drop(id)
            }
        }
    }

    /// Prepares the folder, clears a stale socket file and binds. Returns the listening descriptor.
    private func listen() -> Int32? {
        guard prepareFolder(), clearStaleSocket() else { return nil }
        guard var address = NotchUnixSocket.address(path) else {
            log.error("Socket path too long for a socket address: \(self.path, privacy: .public)")
            return nil
        }
        guard let fd = NotchUnixSocket.makeSocket() else { return fail("socket", nil) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { return fail("bind", fd) }
        guard chmod(path, 0o600) == 0 else { unlink(path); return fail("chmod", fd) }
        guard Darwin.listen(fd, SOMAXCONN) == 0, setNonblocking(fd) else { unlink(path); return fail("listen", fd) }
        return fd
    }

    private func fail(_ call: String, _ fd: Int32?) -> Int32? {
        log.error("Socket not started: \(call, privacy: .public) failed (\(String(cString: strerror(errno)), privacy: .public))")
        if let fd { close(fd) }
        return nil
    }

    /// The folder must be a real directory owned by this user and closed to everyone else; it is created if missing.
    /// A folder owned by another user is refused, not repaired.
    private func prepareFolder() -> Bool {
        let folder = (path as NSString).deletingLastPathComponent
        if mkdir(folder, 0o700) != 0, errno != EEXIST {
            log.error("Socket not started: cannot create \(folder, privacy: .public) (\(String(cString: strerror(errno)), privacy: .public))")
            return false
        }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else {
            log.error("Socket not started: \(folder, privacy: .public) is not a directory owned by this user")
            return false
        }
        guard chmod(folder, 0o700) == 0 else {
            log.error("Socket not started: cannot restrict \(folder, privacy: .public)")
            return false
        }
        return true
    }

    /// A socket file left by a crash is removed. One that still answers belongs to another running instance, and
    /// anything that is not a socket is left alone; both stop this start.
    private func clearStaleSocket() -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return true }
        guard info.st_mode & S_IFMT == S_IFSOCK else {
            log.error("Socket not started: \(self.path, privacy: .public) exists and is not a socket")
            return false
        }
        if let fd = NotchUnixSocket.connect(to: path) {
            close(fd)
            log.error("Socket not started: another Eclipse is listening on \(self.path, privacy: .public)")
            return false
        }
        unlink(path)
        return true
    }

    private func setNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    private func acceptAll(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd >= 0 {
                admit(fd)
            } else if errno == EINTR || errno == ECONNABORTED {
                continue
            } else {
                if errno != EAGAIN { log.error("accept failed (\(String(cString: strerror(errno)), privacy: .public))") }
                return
            }
        }
    }

    /// Keeps a new client when it runs as this user and there is room for it.
    private func admit(_ fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            log.error("Refused a client running as uid \(uid)")
            close(fd)
            return
        }
        guard connections.count < Self.maxClients else {
            log.error("Refused a client: \(Self.maxClients) already connected")
            close(fd)
            return
        }
        NotchUnixSocket.configure(fd)
        guard setNonblocking(fd) else { close(fd); return }
        let id = nextID
        nextID += 1
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receive(id) }
        source.setCancelHandler { close(fd) }
        connections[id] = Connection(fd: fd, source: source)
        source.resume()
        log.info("Client \(id) connected")
    }

    /// Reads whatever arrived and handles each complete line. A line, or an unfinished one, longer than the limit
    /// closes the connection, which also keeps the buffer small.
    private func receive(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: NotchMessage.maxLine)
        while true {
            let count = read(connection.fd, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN { return }
            guard count > 0 else {
                log.info("Client \(id) disconnected")
                drop(id)
                return
            }
            connection.buffer.append(contentsOf: chunk[0..<count])
            while let newline = connection.buffer.firstIndex(of: 0x0A) {
                let line = Data(connection.buffer[connection.buffer.startIndex..<newline])
                connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
                guard line.count < NotchMessage.maxLine else { return oversized(id) }
                handle(line, from: id, connection)
            }
            guard connection.buffer.count < NotchMessage.maxLine else { return oversized(id) }
        }
    }

    private func oversized(_ id: ConnectionID) {
        log.error("Closing client \(id): line longer than \(NotchMessage.maxLine) bytes")
        drop(id)
    }

    private func handle(_ line: Data, from id: ConnectionID, _ connection: Connection) {
        guard !line.isEmpty else { return }
        guard connection.limit.allow(at: DispatchTime.now().uptimeNanoseconds) else {
            if !connection.throttled { log.error("Client \(id) is over the rate limit; dropping lines") }
            connection.throttled = true
            return
        }
        connection.throttled = false
        switch NotchMessage.parse(line) {
        case .success(let message):
            handler?(.message(id, message))
        case .failure(let reason):
            log.error("Rejected a line from client \(id): \(reason.description, privacy: .public)")
        }
    }

    private func drop(_ id: ConnectionID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        handler?(.closed(id))
    }
}
