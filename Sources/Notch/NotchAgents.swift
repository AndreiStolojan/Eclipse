import Foundation

// T3 Code's threads as the notch sees them. Foundation only, so the checks compile it without the app. The wire
// types decode only the fields the notch uses from T3's orchestration protocol 2; unknown fields are ignored and unknown
// enum values read as nil, so a newer T3 degrades a row instead of failing the stream. See docs/t3-code.md.

/// Where T3 Code's local server listens, read from `~/.t3/userdata/server-runtime.json`. The bearer token goes there,
/// so only plain HTTP on this Mac's loopback is accepted: 127.0.0.1, localhost or ::1, an explicit port, and nothing
/// else in the address (no user, password, path beyond "/", query or fragment). Anything else is nil and Eclipse does
/// not connect.
enum NotchT3Origin {
    static func loopback(_ text: String) -> URL? {
        guard let parsed = URLComponents(string: text), parsed.scheme?.lowercased() == "http",
              let host = parsed.host?.lowercased(), ["127.0.0.1", "localhost", "[::1]"].contains(host),
              let port = parsed.port, (1...65535).contains(port),
              parsed.user == nil, parsed.password == nil, parsed.query == nil, parsed.fragment == nil,
              parsed.path.isEmpty || parsed.path == "/" else { return nil }
        var origin = URLComponents()
        origin.scheme = "http"
        origin.host = host
        origin.port = port
        return origin.url
    }
}

/// What a thread is doing, after T3's own notifications and sidebar: one word in the wings and on the page.
enum NotchAgentPhase: String, Equatable, Sendable {
    case running, input, approval, plan, done, failed, stopped, limited, idle
    /// Not a run state: T3's sidebar label for a thread back from a snooze that has not been opened since.
    case woke

    /// The word in the right wing and on a row that needs it.
    var word: String {
        switch self {
        case .running: "Running"
        case .input: "Input"
        case .approval: "Approve"
        case .plan: "Plan"
        case .done: "Done"
        case .failed: "Failed"
        case .stopped: "Stopped"
        case .limited: "Limit"
        case .woke: "Woke"
        case .idle: ""
        }
    }

    /// Phases a thread can enter that alert in the closed notch.
    var alerts: Bool { self != .running && self != .idle }

    /// The thread waits for the user before it can go on.
    var needsYou: Bool { self == .input || self == .approval || self == .plan }

    /// List order: what needs you, then what runs, then the rest by time.
    var rank: Int {
        switch self {
        case .input, .approval: 0
        case .plan, .woke: 1
        case .running: 2
        default: 3
        }
    }
}

/// One thread for the notch: what the alert, the list row and the page header show.
struct NotchAgentThread: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    let projectID: String
    var project: String
    var branch: String?
    var model: String
    var phase: NotchAgentPhase
    /// The run the phase belongs to, so one run alerts once per phase.
    var runID: String?
    var runStarted: Date?
    var runCompleted: Date?
    var updated: Date
    /// The pending question or approval, by T3's request ID.
    var requestID: String?
    var pullRequest: NotchAgentPullRequest?
    /// Moved to T3's Settled shelf, by hand or automatically.
    var settled = false
    /// Hidden on T3's Snoozed shelf until this moment, unless the thread woke early.
    var snoozedUntil: Date?
    var snoozedAt: Date?
    /// When the thread was last opened in T3, which dismisses Woke.
    var lastVisited: Date?

    /// In T3's sidebar: neither settled nor snoozed.
    func active(at now: Date) -> Bool { !settled && !snoozed(at: now) }

    /// On T3's Snoozed shelf: the snooze has not ended and nothing woke the thread early.
    func snoozed(at now: Date) -> Bool { (snoozedUntil ?? .distantPast) > now && earlyWake == nil }

    /// T3's `wokeAt`: a question or approval, or a run that ended after the snooze began, wakes a thread early;
    /// otherwise it wakes when the snooze ends.
    var earlyWake: Date? {
        guard snoozedUntil != nil else { return nil }
        if requestID != nil { return snoozedAt ?? updated }
        guard let snoozedAt, let runCompleted, runCompleted > snoozedAt,
              [.done, .plan, .failed, .limited].contains(phase) else { return nil }
        return runCompleted
    }

    func wokeAt(at now: Date) -> Date? {
        if let earlyWake { return earlyWake }
        guard let snoozedUntil, snoozedUntil <= now else { return nil }
        return snoozedUntil
    }

    /// The word to show: a run state that asks for attention wins, then Woke until the thread is opened in T3.
    func shownPhase(at now: Date) -> NotchAgentPhase {
        guard [.done, .stopped, .idle].contains(phase), !settled, let woke = wokeAt(at: now),
              (lastVisited ?? .distantPast) < woke else { return phase }
        return .woke
    }

    /// T3 snoozes only a thread that neither runs nor waits for an answer.
    var canSnooze: Bool { phase != .running && requestID == nil }

    /// "notch · feat/9-quick-peek", the line under a title.
    var place: String { [project, branch].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ") }

    /// How long the latest run has gone, or went; nil before the first run.
    func runTime(at now: Date) -> TimeInterval? {
        runStarted.map { (runCompleted ?? now).timeIntervalSince($0) }
    }
}

struct NotchAgentPullRequest: Equatable, Sendable, Decodable {
    let number: Int
    let url: URL
}

/// "45s", "6m 12s", "1h 4m".
func notchAgentDuration(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
}

// MARK: - Shell

/// The thread fields of T3's `OrchestrationV2ThreadShell` the notch reads.
struct T3ThreadShell: Decodable, Sendable {
    struct Lineage: Decodable, Sendable { let relationshipToParent: String? }
    struct Model: Decodable, Sendable { let model: String }
    struct Request: Decodable, Sendable { let id: String; let kind: String }
    struct Task: Decodable, Sendable { let kind: String }

    let id: String
    let projectId: String
    let title: String
    let modelSelection: Model?
    let branch: String?
    let status: String
    let activityRunStatus: String?
    let pendingRuntimeRequest: Request?
    let hasActionableProposedPlan: Bool?
    let lastErrorClass: String?
    let latestRunId: String?
    let latestRunStartedAt: String?
    let latestRunCompletedAt: String?
    let pendingBackgroundTasks: [Task]?
    let branchPullRequest: NotchAgentPullRequest?
    let lineage: Lineage?
    let updatedAt: String
    let settledOverride: String?
    let snoozedUntil: String?
    let snoozedAt: String?
    let lastVisitedAt: String?
    let archivedAt: String?
    let deletedAt: String?

    /// T3's `resolveThreadAwarenessPhaseV2`, plus the plan and usage limit states of its sidebar. A run that finished
    /// with subagents or monitors still working stays running, as in T3: they wake the agent again.
    var phase: NotchAgentPhase {
        if pendingRuntimeRequest?.kind == "user_input" { return .input }
        if let kind = pendingRuntimeRequest?.kind, kind != "auth_refresh" { return .approval }
        if lastErrorClass == "usage_limit" { return .limited }
        switch activityRunStatus ?? status {
        case "preparing", "starting", "running", "waiting": return .running
        case "completed":
            let held = pendingBackgroundTasks?.contains { $0.kind != "command" } ?? false
            if held { return .running }
            return hasActionableProposedPlan == true ? .plan : .done
        case "failed": return .failed
        case "interrupted", "cancelled": return .stopped
        default: return hasActionableProposedPlan == true ? .plan : .idle
        }
    }

    /// Subagent threads belong to their parent's row; archived and deleted threads leave the notch.
    var listed: Bool { lineage?.relationshipToParent != "subagent" && archivedAt == nil && deletedAt == nil }

    func thread(projects: [String: String]) -> NotchAgentThread {
        NotchAgentThread(id: id, title: title, projectID: projectId, project: projects[projectId] ?? "", branch: branch,
                         model: modelSelection?.model ?? "", phase: phase, runID: latestRunId,
                         runStarted: latestRunStartedAt.flatMap(T3Date.parse),
                         runCompleted: latestRunCompletedAt.flatMap(T3Date.parse),
                         updated: T3Date.parse(updatedAt) ?? .distantPast, requestID: pendingRuntimeRequest?.id,
                         pullRequest: branchPullRequest, settled: settledOverride == "settled",
                         snoozedUntil: snoozedUntil.flatMap(T3Date.parse), snoozedAt: snoozedAt.flatMap(T3Date.parse),
                         lastVisited: lastVisitedAt.flatMap(T3Date.parse))
    }
}

struct T3ProjectShell: Decodable, Sendable {
    let id: String
    let title: String
}

/// One value of the `orchestration.subscribeShell` stream. Kinds this build does not know decode as `.other`.
enum T3ShellItem: Decodable, Sendable {
    case snapshot(threads: [T3ThreadShell], projects: [T3ProjectShell])
    /// A later snapshot that only refreshes projects; its thread lists are empty, not authoritative.
    case projectsRefreshed([T3ProjectShell])
    case threadUpdated(T3ThreadShell)
    case threadRemoved(String)
    case projectUpdated(T3ProjectShell)
    case other

    private enum Keys: String, CodingKey { case kind, snapshot, thread, threadId, project, resolvedRepositoryIdentityRoots }
    private struct Snapshot: Decodable { let threads: [Lossy<T3ThreadShell>]; let projects: [Lossy<T3ProjectShell>] }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "snapshot":
            let snapshot = try container.decode(Snapshot.self, forKey: .snapshot)
            if container.contains(.resolvedRepositoryIdentityRoots) {
                self = .projectsRefreshed(snapshot.projects.compactMap(\.value))
                return
            }
            self = .snapshot(threads: snapshot.threads.compactMap(\.value), projects: snapshot.projects.compactMap(\.value))
        case "thread.updated": self = .threadUpdated(try container.decode(T3ThreadShell.self, forKey: .thread))
        case "thread.removed": self = .threadRemoved(try container.decode(String.self, forKey: .threadId))
        case "project.updated": self = .projectUpdated(try container.decode(T3ProjectShell.self, forKey: .project))
        default: self = .other
        }
    }
}

/// Decodes an element or nil, so one malformed thread does not drop the whole snapshot.
struct Lossy<Value: Decodable & Sendable>: Decodable, Sendable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
}

enum T3Date {
    /// T3 writes ISO 8601 with milliseconds; plain seconds are accepted too.
    static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: .iso8601)
    }
}

// MARK: - Thread detail

/// A question the agent asked, as T3 shows it.
struct NotchAgentQuestion: Equatable, Sendable, Decodable {
    struct Option: Equatable, Sendable, Decodable {
        let label: String
        let description: String?
        let value: String?
        /// What T3 sends back for this option.
        var answer: String { value ?? label }
    }
    let id: String
    let header: String
    let question: String
    let options: [Option]
    let multiSelect: Bool?
}

/// A decision T3 offers for an approval, with the label it shows.
struct NotchAgentDecision: Equatable, Sendable, Decodable {
    let decision: String
    let label: String

    /// T3's own fallback when the provider names no options: Cancel is left to T3 itself.
    static let fallback = [
        NotchAgentDecision(decision: "decline", label: "Decline"),
        NotchAgentDecision(decision: "acceptForSession", label: "This session"),
        NotchAgentDecision(decision: "accept", label: "Approve"),
    ]
}

/// What the thread waits for: answers to questions, or a decision on a command, file or tool.
enum NotchAgentRequest: Equatable, Sendable {
    case questions(id: String, [NotchAgentQuestion])
    case approval(id: String, kind: String, prompt: String?, decisions: [NotchAgentDecision])

    var id: String {
        switch self {
        case .questions(let id, _), .approval(let id, _, _, _): id
        }
    }

    /// "Wants to run a command", the line over an approval's prompt.
    static func summary(kind: String) -> String {
        switch kind {
        case "command": "Wants to run a command"
        case "file-read": "Wants to read files"
        case "file-change": "Wants to change files"
        case "mcp-elicitation": "A tool asks for input"
        default: "Asks for permission"
        }
    }
}

/// An image of a thread: a file the agent pointed to in a reply, or one the user attached, which T3 keeps as
/// `~/.t3/userdata/attachments/<id>.<extension>`.
enum NotchAgentImage: Equatable, Hashable, Sendable {
    case file(path: String, name: String)
    case attachment(id: String, name: String)

    var name: String {
        switch self {
        case .file(_, let name), .attachment(_, let name): name
        }
    }

    /// `![alt](target)`, `![alt](<target with spaces>)` and `![alt](target "title")`.
    static let pattern = #/!\[(?<alt>[^\]]*)\]\(\s*(?:<(?<angled>[^>]+)>|(?<plain>[^)\s]+))(?:\s+"[^"]*")?\s*\)/#

    /// The local file an image target names: an absolute path, percent-encoded or not, or a `file://` URL.
    static func path(of target: String) -> String? {
        if target.hasPrefix("file://") { return URL(string: target)?.path }
        guard target.hasPrefix("/") else { return nil }
        return target.removingPercentEncoding ?? target
    }

    /// The local images in a reply; web and relative images are not files the notch can show.
    static func references(in markdown: String) -> [NotchAgentImage] {
        markdown.matches(of: pattern).compactMap { match in
            guard let path = path(of: String(match.angled ?? match.plain ?? "")) else { return nil }
            let alt = String(match.alt)
            return .file(path: path, name: alt.isEmpty ? URL(fileURLWithPath: path).lastPathComponent : alt)
        }
    }
}

/// An image found on disk, with the name to show for it.
struct NotchAgentImageFile: Equatable, Sendable {
    let url: URL
    let name: String
}

/// The thread page beyond the shell: what the agent last said, the files changed and the open request. Tool calls,
/// commands and subagents stay out (only what the agent says).
struct NotchAgentDetail: Equatable, Sendable {
    /// The thread's images, newest first: the agent's and the user's (a strip of thumbnails, opened in Quick Look).
    var images: [NotchAgentImage] = []
    /// The same images found on disk, filled in by the client off the main thread.
    var imageFiles: [NotchAgentImageFile] = []
    /// The replies already parsed, so the page does not parse Markdown while it draws.
    private(set) var messageBlocks: [NotchMarkdownBlock] = []
    private(set) var lastMessageBlocks: [NotchMarkdownBlock] = []
    /// The agent's latest reply in the latest run, nil until it has said something in it. Fixed at init, with its
    /// parsed blocks.
    let message: String?
    /// The latest reply of any run, for a finished thread whose latest run said nothing.
    let lastMessage: String?
    var files: Int
    var request: NotchAgentRequest?
    var runID: String?

    /// Parses the replies here, which runs off the main thread when the client reads a snapshot.
    init(images: [NotchAgentImage] = [], message: String?, lastMessage: String?, files: Int, request: NotchAgentRequest?,
         runID: String?) {
        self.images = images
        self.message = message
        self.lastMessage = lastMessage
        self.files = files
        self.request = request
        self.runID = runID
        messageBlocks = message.map(NotchMarkdownBlock.parse) ?? []
        lastMessageBlocks = lastMessage == message ? messageBlocks : lastMessage.map(NotchMarkdownBlock.parse) ?? []
    }
}

/// The parts of T3's thread snapshot (`GET /api/orchestration/threads/:id/bounded`) the page reads.
struct T3ThreadSnapshot: Decodable, Sendable {
    struct Projection: Decodable, Sendable {
        struct Run: Decodable, Sendable { let id: String }
        let runs: [Lossy<Run>]
        let turnItems: [Lossy<T3TurnItem>]
    }
    let projection: Projection

    /// Reads the latest run: the agent's last reply and the files it edited, and the request still pending. Items
    /// go in timeline order, whatever order the snapshot lists them in.
    func detail(pendingRequest: String?) -> NotchAgentDetail {
        let items = projection.turnItems.compactMap(\.value).sorted { ($0.ordinal ?? 0) < ($1.ordinal ?? 0) }
        let runID = projection.runs.compactMap(\.value).last?.id
        let run = items.filter { $0.runId == runID }
        let reply = { (items: [T3TurnItem]) in items.last { $0.type == "assistant_message" && !($0.text ?? "").isEmpty }?.text }
        let files = Set(run.compactMap { $0.type == "file_change" ? $0.fileName : nil }).count
        let request = pendingRequest.flatMap { id in items.last { $0.requestId == id }?.request }
        let images = items.reversed().flatMap { item -> [NotchAgentImage] in
            switch item.type {
            case "user_message":
                return (item.attachments ?? []).reversed().compactMap { attachment in
                    attachment.type == "image" ? .attachment(id: attachment.id, name: attachment.name ?? "Image") : nil
                }
            case "assistant_message": return NotchAgentImage.references(in: item.text ?? "").reversed()
            default: return []
            }
        }
        return NotchAgentDetail(images: images, message: reply(run), lastMessage: reply(items), files: files, request: request,
                                runID: runID)
    }
}

/// One timeline item; the fields depend on `type`.
struct T3TurnItem: Decodable, Sendable {
    let type: String
    let status: String
    let runId: String?
    let ordinal: Int?
    let text: String?
    let fileName: String?
    /// A user message's attachments; images among them show on the page.
    let attachments: [Attachment]?

    struct Attachment: Decodable, Sendable {
        let type: String
        let id: String
        let name: String?
    }
    let requestId: String?
    let requestKind: String?
    let prompt: String?
    let options: [NotchAgentDecision]?
    let questions: [NotchAgentQuestion]?

    var request: NotchAgentRequest? {
        guard let requestId else { return nil }
        switch type {
        case "user_input_request": return .questions(id: requestId, questions ?? [])
        case "approval_request":
            let decisions = options.map { $0.filter { $0.decision != "cancel" } } ?? NotchAgentDecision.fallback
            return .approval(id: requestId, kind: requestKind ?? "permission", prompt: prompt, decisions: decisions)
        default: return nil
        }
    }
}

// MARK: - Alerts

/// A thread entering a phase that alerts, for the closed notch. Several of the same phase at once read as one alert
/// with a count.
struct NotchAgentAlert: Equatable, Sendable {
    var thread: NotchAgentThread
    var count = 1

    var word: String { count > 1 ? "\(count) \(thread.phase.word)" : thread.phase.word }

    /// A later alert joins this one when they say the same thing; otherwise it replaces it.
    mutating func merge(_ other: NotchAgentAlert) {
        if other.thread.phase == thread.phase, other.thread.id != thread.id { count += other.count } else { count = other.count }
        thread = other.thread
    }
}

/// Keeps the listed threads and reports each thread's entry into an alerting phase once per run. The first snapshot
/// only records: threads that finished before Eclipse connected do not alert.
struct NotchAgentTracker: Sendable {
    private(set) var threads: [String: NotchAgentThread] = [:]
    private var projects: [String: String] = [:]
    private var seeded = false

    /// Applies one stream value; returns the alerts it raised.
    mutating func apply(_ item: T3ShellItem) -> [NotchAgentAlert] {
        switch item {
        case .snapshot(let shells, let projectShells):
            projects = Dictionary(projectShells.map { ($0.id, $0.title) }) { $1 }
            let old = threads
            threads = Dictionary(shells.filter(\.listed).map { ($0.id, $0.thread(projects: projects)) }) { $1 }
            // A resubscription after a reconnect compares against what was known; the very first one does not.
            defer { seeded = true }
            guard seeded else { return [] }
            return threads.values.compactMap { alert(from: old[$0.id], to: $0) }
        case .threadUpdated(let shell):
            guard shell.listed else { threads[shell.id] = nil; return [] }
            let thread = shell.thread(projects: projects)
            let old = threads[shell.id]
            threads[shell.id] = thread
            guard seeded else { return [] }
            return alert(from: old, to: thread).map { [$0] } ?? []
        case .threadRemoved(let id):
            threads[id] = nil
            return []
        case .projectUpdated(let project):
            rename([project])
            return []
        case .projectsRefreshed(let refreshed):
            rename(refreshed)
            return []
        case .other:
            return []
        }
    }

    private mutating func rename(_ refreshed: [T3ProjectShell]) {
        for project in refreshed {
            projects[project.id] = project.title
            for (id, thread) in threads where thread.projectID == project.id { threads[id]?.project = project.title }
        }
    }

    /// A phase that alerts, newly entered: a different phase, or the same phase in a later run or for a new request.
    /// Settled and snoozed threads stay quiet, as they are out of T3's sidebar.
    private func alert(from old: NotchAgentThread?, to new: NotchAgentThread) -> NotchAgentAlert? {
        guard new.phase.alerts, new.active(at: .now) else { return nil }
        if let old, old.phase == new.phase, old.runID == new.runID, old.requestID == new.requestID { return nil }
        return NotchAgentAlert(thread: new)
    }

    /// The page: the threads in T3's sidebar, needs you first, then running, then the rest, newest first within each.
    func list(at now: Date) -> [NotchAgentThread] {
        threads.values.filter { $0.active(at: now) }
            .sorted { ($0.shownPhase(at: now).rank, $1.updated) < ($1.shownPhase(at: now).rank, $0.updated) }
    }

    /// Threads whose snooze ended in `(from, to]`, as Woke alerts. A snooze end is a moment, not a stream value,
    /// so the client calls this when it comes.
    func woken(after from: Date, through to: Date) -> [NotchAgentAlert] {
        threads.values.compactMap { thread in
            guard let until = thread.snoozedUntil, until > from, until <= to, !thread.settled, thread.earlyWake == nil else { return nil }
            var woke = thread
            woke.phase = .woke
            return NotchAgentAlert(thread: woke)
        }
    }

    /// The next snooze to end, for the client's one sleeping task.
    func nextWake(after now: Date) -> Date? {
        threads.values.filter { !$0.settled && $0.earlyWake == nil }.compactMap(\.snoozedUntil).filter { $0 > now }.min()
    }

    mutating func reset() { threads = [:]; seeded = false }
}

// MARK: - RPC frames

/// Effect RPC frames over T3's WebSocket, one JSON object per message. The client acknowledges every chunk, or the
/// stream stalls, and answers the server's pings.
enum T3Frame {
    case chunk(requestID: String, values: [Data])
    case exit(requestID: String, success: Bool, message: String?)
    case ping
    case other

    static func parse(_ data: Data) -> T3Frame {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["_tag"] as? String else { return .other }
        switch tag {
        case "Chunk":
            guard let id = object["requestId"] as? String, let values = object["values"] as? [Any] else { return .other }
            return .chunk(requestID: id, values: values.compactMap { try? JSONSerialization.data(withJSONObject: $0) })
        case "Exit":
            guard let id = object["requestId"] as? String else { return .other }
            let exit = object["exit"] as? [String: Any]
            let success = exit?["_tag"] as? String == "Success"
            return .exit(requestID: id, success: success, message: success ? nil : Self.failure(exit))
        case "Ping": return .ping
        default: return .other
        }
    }

    /// The readable part of a failed exit: the error's message if T3 sent one.
    private static func failure(_ exit: [String: Any]?) -> String? {
        guard let cause = exit?["cause"] as? [String: Any] else { return nil }
        let error = cause["error"] as? [String: Any] ?? cause["defect"] as? [String: Any]
        return error?["message"] as? String
    }

    static func request(id: String, tag: String, payload: [String: Any]) -> Data {
        encode(["_tag": "Request", "id": id, "tag": tag, "payload": payload, "headers": [Any]()])
    }

    static func ack(_ requestID: String) -> Data { encode(["_tag": "Ack", "requestId": requestID]) }

    static let pong = encode(["_tag": "Pong"])

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// The commands the notch sends through `orchestration.dispatchCommand`.
enum T3Command {
    /// Answers keyed by question ID: one option's answer, or several for a multiple choice.
    case answer(threadID: String, requestID: String, answers: [String: [String]], multi: Set<String>)
    case decide(threadID: String, requestID: String, decision: String)
    case interrupt(threadID: String, runID: String)
    case snooze(threadID: String, until: Date)

    var payload: [String: Any] {
        let commandID = UUID().uuidString.lowercased()
        switch self {
        case .answer(let thread, let request, let answers, let multi):
            let values = Dictionary(uniqueKeysWithValues: answers.map { id, picks -> (String, Any) in
                (id, multi.contains(id) ? picks : picks.first ?? "")
            })
            return ["type": "runtime-request.respond", "commandId": commandID, "threadId": thread, "requestId": request,
                    "answers": values]
        case .decide(let thread, let request, let decision):
            return ["type": "runtime-request.respond", "commandId": commandID, "threadId": thread, "requestId": request,
                    "decision": decision]
        case .interrupt(let thread, let run):
            return ["type": "run.interrupt", "commandId": commandID, "threadId": thread, "runId": run, "holdQueue": true]
        case .snooze(let thread, let until):
            return ["type": "thread.snooze", "commandId": commandID, "threadId": thread,
                    "snoozedUntil": until.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true)
                        .timeZone(separator: .omitted))]
        }
    }
}

/// T3's snooze choices, in its order: in 1 hour, in 3 hours, this evening at 18:00 when that is over an hour away,
/// tomorrow at 9:00, and next Monday at 9:00 when that is not tomorrow.
struct NotchSnoozeChoice: Equatable, Sendable {
    let label: String
    let until: Date

    static func choices(at now: Date, calendar: Calendar = .current) -> [NotchSnoozeChoice] {
        func at(_ hour: Int, daysAhead: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysAhead, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        var choices = [NotchSnoozeChoice(label: "1 h", until: now.addingTimeInterval(3600)),
                       NotchSnoozeChoice(label: "3 h", until: now.addingTimeInterval(3 * 3600))]
        let evening = at(18, daysAhead: 0)
        if evening.timeIntervalSince(now) > 3600 { choices.append(NotchSnoozeChoice(label: "Evening", until: evening)) }
        let tomorrow = at(9, daysAhead: 1)
        choices.append(NotchSnoozeChoice(label: "Tomorrow", until: tomorrow))
        // Days until Monday, a full week on a Monday; Calendar counts Sunday as 1.
        let weekday = calendar.component(.weekday, from: now)
        let monday = at(9, daysAhead: (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7)
        if monday != tomorrow { choices.append(NotchSnoozeChoice(label: "Monday", until: monday)) }
        return choices
    }
}
