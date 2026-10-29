import AppKit
import Combine
import os
import Security

/// Where the T3 Code link stands, for the settings page.
enum NotchT3Status: Equatable {
    case off, notInstalled, notRunning, connecting, connected
    /// T3 refused the token: revoked from T3 or expired. Turning Connect off and on issues a new one.
    case rejected
    case failed(String)

    var label: String {
        switch self {
        case .off: "Off"
        case .notInstalled: "T3 Code not installed"
        case .notRunning: "T3 Code not running"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .rejected: "Access revoked, reconnect"
        case .failed(let reason): reason
        }
    }
}

/// The link to T3 Code: one WebSocket to T3's local server, subscribed to the thread shell stream, plus a
/// thread snapshot fetched over HTTP for the page that shows it and for a pending question or approval. Answers,
/// approvals and Stop go back as T3's own commands. It connects while T3 Code runs and the link is on; nothing polls.
///
/// Access is a bearer session that Connect issues once through T3's bundled CLI (`t3 auth session issue`) and keeps
/// in the Keychain; Revoke on the settings page revokes it, turning Connect off only disconnects. T3 lists it under
/// its sessions as "Eclipse". A session T3 refuses is never replaced behind the user's back: Connect has to be turned
/// off and on again.
@MainActor
final class NotchT3: ObservableObject {
    nonisolated static let bundleID = "com.t3tools.t3code"

    @Published private(set) var status = NotchT3Status.off
    /// Threads for the page: those in T3's sidebar, needs you first, then running, then the rest.
    @Published private(set) var threads: [NotchAgentThread] = []
    /// Page details by thread ID, fetched on demand.
    @Published private(set) var details: [String: NotchAgentDetail] = [:]
    /// The moment the list was last judged against the clock, so a snooze ending redraws Woke.
    @Published private(set) var listedAt = Date.now
    /// Threads whose answer is on its way, so the page can hold its buttons.
    @Published private(set) var sending: Set<String> = []
    /// A thread entered a phase that alerts.
    var onAlert: ((NotchAgentAlert) -> Void)?
    /// T3 refused the token: the owner turns Connect off, so only the user can ask T3 for a new session.
    var onRejected: (() -> Void)?
    /// The thread whose page is open; its detail follows every update.
    var watched: String? { didSet { if let watched, watched != oldValue { fetchDetail(watched) } } }

    private var enabled = false
    private var tracker = NotchAgentTracker()
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var origin: URL?
    /// The token, read from the Keychain once: macOS may ask for the login password on every read by a new build.
    private var credentialCache: NotchT3Credential?
    private var nextRequest = 1
    private var replies: [String: CheckedContinuation<Bool, Never>] = [:]
    private var connectTask: Task<Void, Never>?
    /// Bumped for every connection attempt, so a cancelled attempt finishing late does not clear a newer one.
    private var connectGeneration = 0
    /// One issuance at a time, shared by attempts, so a quick off and on cannot mint two sessions.
    private var issuing: Task<NotchT3Credential?, Never>?
    /// Bumped by Forget, so a credential that arrives after it is revoked rather than cached.
    private var credentialGeneration = 0
    /// Forget's revocation; a later issuance waits for it, so its Keychain deletion cannot remove the new session.
    private var forgetting: Task<Void, Never>?
    /// Set when T3 refused the token; cleared when Connect is turned on again.
    private var rejected = false
    /// The `subscribeShell` request; its end means the list stopped following T3.
    private var shellRequest: String?
    /// Sleeps until the next snooze ends, then shows the thread again with a Woke alert.
    private var wakeTask: Task<Void, Never>?
    /// Snoozes that ended up to here have been seen; earlier ones, from before connecting, do not alert.
    private var wakeChecked = Date.now
    private var retryTask: Task<Void, Never>?
    private var retries = 0
    private var fetching: Set<String> = []
    private var refetch: Set<String> = []
    /// Bumped whenever the socket drops, so a detail fetch from an older connection neither publishes nor touches the
    /// fetch state of a newer one.
    private var link = 0
    private var presence: NSKeyValueObservation?
    private let log = Logger(subsystem: "ro.andrei.NotchLab", category: "t3")

    init() {}

    /// Fixture rendering: fixed threads and details, never connected.
    init(preview threads: [NotchAgentThread], details: [String: NotchAgentDetail] = [:], status: NotchT3Status = .connected) {
        self.threads = threads
        self.details = details
        self.status = status
    }

    /// The installed T3 Code, nightly or stable; both use the same bundle ID.
    /// Looked up once per launch; the views ask on every render.
    nonisolated static let appURL: URL? = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    nonisolated static let icon: NSImage? = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    private static var running: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    /// Follows the Connect switch. Turning it on the first time issues the token; off only disconnects.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on {
            rejected = false
            presence = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
                Task { @MainActor in self?.presenceChanged() }
            }
            presenceChanged()
        } else {
            presence = nil
            disconnect(status: rejected ? .rejected : .off)
        }
    }

    /// Revokes the token and forgets it, from the settings page, which turns Connect off first.
    func forget() {
        let cached = credentialCache
        // A token still being issued is revoked too once it arrives.
        let pending = issuing, previous = forgetting
        credentialCache = nil
        issuing = nil
        credentialGeneration += 1
        disconnect(status: .off)
        forgetting = Task.detached {
            await previous?.value
            let issued = await pending?.value
            for credential in Set([cached ?? NotchT3Credential.load(), issued].compactMap { $0?.sessionID }) {
                _ = try? NotchT3CLI.run(["auth", "session", "revoke", credential])
            }
            NotchT3Credential.delete()
        }
    }

    /// The thread's images found on disk; missing files drop out. Attachments are found by ID whatever their
    /// extension, from one listing of T3's attachments folder.
    nonisolated static func files(for images: [NotchAgentImage]) -> [NotchAgentImageFile] {
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".t3/userdata/attachments")
        let listing = images.contains { if case .attachment = $0 { true } else { false } }
            ? (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] : []
        let byID = Dictionary(listing.map { (($0 as NSString).deletingPathExtension, $0) }) { first, _ in first }
        return images.compactMap { image in
            switch image {
            case .file(let path, let name):
                return FileManager.default.fileExists(atPath: path) ? NotchAgentImageFile(url: URL(fileURLWithPath: path), name: name) : nil
            case .attachment(let id, let name):
                return byID[id].map { NotchAgentImageFile(url: folder.appending(path: $0), name: name) }
            }
        }
    }

    /// Brings T3 Code forward; T3 has no link that opens one thread from outside.
    func openApp() {
        guard let url = Self.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func presenceChanged() {
        guard enabled, !rejected else { return }
        guard Self.appURL != nil else { disconnect(status: .notInstalled); return }
        guard Self.running else { disconnect(status: .notRunning); return }
        guard socket == nil, retryTask == nil, connectTask == nil else { return }
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task {
            await connect()
            if connectGeneration == generation { connectTask = nil }
        }
    }

    private func connect() async {
        guard enabled, socket == nil else { return }
        status = .connecting
        guard let credential = await credential() else { return }
        guard let origin = Self.serverOrigin(), var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else {
            scheduleRetry(); return
        }
        components.scheme = "ws"
        components.path = "/ws"
        components.queryItems = [URLQueryItem(name: "orchestrationProtocol", value: "2")]
        guard let url = components.url, enabled, !rejected, !Task.isCancelled, socket == nil else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral, delegate: NotchNoRedirects(), delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        // Snapshots of a hundred threads run to a megabyte.
        task.maximumMessageSize = 16 << 20
        self.session = session
        self.origin = origin
        socket = task
        task.resume()
        let subscription = requestID()
        shellRequest = subscription
        send(T3Frame.request(id: subscription, tag: "orchestration.subscribeShell", payload: [:]))
        receive(task)
    }

    /// The stored token, or a new one issued through T3's CLI. Nil after a failure, which the status reports. The
    /// Keychain is read off the main thread: macOS may hold the read behind a password prompt.
    private func credential() async -> NotchT3Credential? {
        if let credentialCache { return credentialCache }
        let generation = credentialGeneration
        let issuance = issuing ?? Task.detached { [forgetting] () -> NotchT3Credential? in
            await forgetting?.value
            if let stored = NotchT3Credential.load() { return stored }
            guard let output = try? NotchT3CLI.run(["auth", "session", "issue", "--label", "Eclipse", "--ttl", "365d", "--json"]),
                  let credential = try? JSONDecoder().decode(NotchT3Credential.self, from: output) else { return nil }
            // Saved even if the attempt was cancelled meanwhile, so the session is never orphaned.
            NotchT3Credential.save(credential)
            return credential
        }
        issuing = issuance
        let credential = await issuance.value
        if issuing == issuance { issuing = nil }
        // Forget ran meanwhile and revokes this credential.
        guard generation == credentialGeneration else { return nil }
        if let credential {
            credentialCache = credential
        } else {
            log.error("Could not read or issue a T3 token")
            status = .failed("Could not get access from T3 Code")
        }
        return credential
    }

    /// T3 writes its server's address when it starts; the port can change between launches. Only a loopback
    /// address is used, since the token goes there (`NotchT3Origin`).
    private static func serverOrigin() -> URL? {
        let file = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".t3/userdata/server-runtime.json")
        struct Runtime: Decodable { let origin: String }
        guard let data = try? Data(contentsOf: file), let runtime = try? JSONDecoder().decode(Runtime.self, from: data) else { return nil }
        return NotchT3Origin.loopback(runtime.origin)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handle(Data(text.utf8))
                    case .data(let data): self.handle(data)
                    @unknown default: break
                    }
                    self.receive(task)
                case .failure(let error):
                    self.closed(task, error: error)
                }
            }
        }
    }

    private func handle(_ data: Data) {
        switch T3Frame.parse(data) {
        case .chunk(let id, let values):
            send(T3Frame.ack(id))
            if status != .connected { status = .connected; retries = 0; wakeChecked = .now }
            var alerts: [NotchAgentAlert] = []
            for value in values {
                do {
                    let item = try JSONDecoder().decode(T3ShellItem.self, from: value)
                    alerts += tracker.apply(item)
                    switch item {
                    case .threadUpdated(let shell): updated(shell.id)
                    // After a reconnect the open page and pending requests are read again.
                    case .snapshot: tracker.threads.keys.forEach(updated)
                    default: break
                    }
                } catch {
                    // One value this build cannot read is skipped; the stream goes on.
                    log.error("Skipped a T3 shell value: \(error.localizedDescription, privacy: .public)")
                }
            }
            publish()
            alerts.forEach { onAlert?($0) }
        case .exit(let id, let success, let message):
            if !success { log.error("T3 refused a request: \(message ?? "no message", privacy: .public)") }
            if id == shellRequest {
                // The stream ended while the socket stays open: start over rather than show a frozen list.
                drop()
                scheduleRetry()
                return
            }
            replies.removeValue(forKey: id)?.resume(returning: success)
        case .ping:
            send(T3Frame.pong)
        case .other:
            break
        }
    }

    /// The list follows T3's sidebar: settled and snoozed threads leave it, and a snooze ending brings its thread
    /// back at that moment.
    private func publish() {
        let now = Date.now
        listedAt = now
        let list = tracker.list(at: now)
        if list != threads { threads = list }
        wakeTask?.cancel()
        if let next = tracker.nextWake(after: now) {
            wakeTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 0.5))
                guard !Task.isCancelled, let self else { return }
                let now = Date.now
                let woken = self.tracker.woken(after: self.wakeChecked, through: now)
                self.wakeChecked = now
                self.publish()
                woken.forEach { self.onAlert?($0) }
            }
        }
        details = details.filter { id, _ in tracker.threads[id] != nil }
    }

    /// A thread changed: the open page follows it, and a new question or approval is read so it can be answered.
    private func updated(_ id: String) {
        guard let thread = tracker.threads[id] else { return }
        if id == watched || thread.requestID != nil && details[id]?.request?.id != thread.requestID { fetchDetail(id) }
    }

    /// Reads one thread's snapshot. A change during a fetch fetches once more afterwards, never in parallel.
    func fetchDetail(_ id: String) {
        guard fetching.insert(id).inserted else { refetch.insert(id); return }
        guard let origin, let credential = credentialCache, let session else { fetching.remove(id); return }
        var request = URLRequest(url: origin.appending(path: "api/orchestration/threads/\(id)/bounded"))
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("2", forHTTPHeaderField: "x-t3-orchestration-protocol")
        let started = link
        Task {
            defer {
                if link == started {
                    fetching.remove(id)
                    if refetch.remove(id) != nil { fetchDetail(id) }
                }
            }
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let pending = tracker.threads[id]?.requestID
            // Decoding, Markdown parsing and finding the images on disk all happen off the main thread.
            let detail = await Task.detached { () -> NotchAgentDetail? in
                guard var detail = try? JSONDecoder().decode(T3ThreadSnapshot.self, from: data).detail(pendingRequest: pending) else {
                    return nil
                }
                detail.imageFiles = Self.files(for: detail.images)
                return detail
            }.value
            // A detail for a connection that dropped, or a thread that left the list, is stale.
            guard link == started, tracker.threads[id] != nil, let detail, details[id] != detail else { return }
            details[id] = detail
        }
    }

    /// Sends a command and waits for T3's verdict.
    @discardableResult
    func dispatch(_ command: T3Command, for thread: String) async -> Bool {
        guard socket != nil else { return false }
        sending.insert(thread)
        defer { sending.remove(thread) }
        let id = requestID()
        // Whichever comes first, T3's verdict, a failed send, the socket closing or 10 s, ends the wait; taking the
        // continuation out of `replies` makes sure it resumes once.
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.replies.removeValue(forKey: id)?.resume(returning: false)
        }
        defer { timeout.cancel() }
        let success = await withCheckedContinuation { continuation in
            replies[id] = continuation
            send(T3Frame.request(id: id, tag: "orchestration.dispatchCommand", payload: command.payload)) { [weak self] in
                self?.replies.removeValue(forKey: id)?.resume(returning: false)
            }
        }
        if success { fetchDetail(thread) }
        return success
    }

    private func send(_ data: Data, failed: (@MainActor () -> Void)? = nil) {
        guard let socket, let text = String(data: data, encoding: .utf8) else { failed?(); return }
        socket.send(.string(text)) { error in
            guard error != nil, let failed else { return }
            Task { @MainActor in failed() }
        }
    }

    private func requestID() -> String {
        defer { nextRequest += 1 }
        return String(nextRequest)
    }

    /// A refused upgrade means the token no longer works; anything else retries while T3 runs.
    private func closed(_ task: URLSessionWebSocketTask, error: Error) {
        let code = (task.response as? HTTPURLResponse)?.statusCode
        log.notice("T3 socket closed (\(code ?? 0)): \(error.localizedDescription, privacy: .public)")
        drop()
        if code == 401 || code == 403 {
            credentialCache = nil
            rejected = true
            NotchT3Credential.delete()
            disconnect(status: .rejected)
            onRejected?()
            return
        }
        guard enabled else { return }
        if Self.running { scheduleRetry() } else { status = .notRunning }
    }

    /// Waits 2, 5, 10 then 30 s between attempts; T3 quitting or the switch turning off ends the wait.
    private func scheduleRetry() {
        guard enabled, retryTask == nil else { return }
        let delay = [2.0, 5, 10, 30][min(retries, 3)]
        retries += 1
        status = .connecting
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            self.presenceChanged()
        }
    }

    private func drop() {
        link += 1
        fetching.removeAll()
        refetch.removeAll()
        shellRequest = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        for continuation in replies.values { continuation.resume(returning: false) }
        replies.removeAll()
    }

    private func disconnect(status: NotchT3Status) {
        wakeTask?.cancel()
        wakeTask = nil
        connectTask?.cancel()
        connectTask = nil
        connectGeneration += 1
        retryTask?.cancel()
        retryTask = nil
        retries = 0
        drop()
        tracker.reset()
        threads = []
        details = [:]
        self.status = status
    }
}

/// The bearer session T3 issued for Eclipse, kept in the login Keychain.
struct NotchT3Credential: Codable {
    let sessionID: String
    let token: String

    private enum CodingKeys: String, CodingKey { case sessionID = "sessionId", token }

    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "ro.andrei.NotchLab") + ".t3code",
                                               kSecAttrAccount as String: "session"]

    static func load() -> NotchT3Credential? {
        var result: AnyObject?
        var search = query
        search[kSecReturnData as String] = true
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ credential: NotchT3Credential) {
        guard let data = try? JSONEncoder().encode(credential) else { return }
        delete()
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() { SecItemDelete(query as CFDictionary) }
}

/// Runs T3 Code's bundled CLI the way the desktop app starts its server: the Electron binary as Node.
enum NotchT3CLI {
    enum Failure: Error { case notInstalled, failed(Int32) }

    static func run(_ arguments: [String]) throws -> Data {
        guard let app = NotchT3.appURL, let bundle = Bundle(url: app), let executable = bundle.executableURL else {
            throw Failure.notInstalled
        }
        let script = app.appending(path: "Contents/Resources/app.asar/apps/server/dist/bin.mjs")
        let environment = ProcessInfo.processInfo.environment.merging(["ELECTRON_RUN_AS_NODE": "1"]) { $1 }
        // A CLI stuck on a locked database must not hold Connect forever.
        let result = try NotchProcess(executable: executable, arguments: [script.path] + arguments, environment: environment)
            .run(timeout: 30)
        guard result.status == 0, !result.signalled else { throw Failure.failed(result.status) }
        return result.output
    }
}
