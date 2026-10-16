import AppKit

/// The branch an install follows: `main` for Eclipse, `beta` for Eclipse Beta.
enum NotchChannel: String {
    case stable, beta

    var branch: String { self == .beta ? "beta" : "main" }

    /// The command that builds and installs the latest commit of this channel, the same one the README gives.
    var installCommand: String {
        "curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Eclipse/main/install.sh | bash"
            + (self == .beta ? " -s -- --beta" : "")
    }
}

/// What this copy of the app was built from. scripts/build.sh passes the channel and the git commit to xcodebuild,
/// which writes them into Info.plist; a build from Xcode, or from a folder without git, has no commit.
struct NotchBuild: Equatable {
    let version: String
    let channel: NotchChannel
    /// The full commit SHA in lowercase, nil for a local build.
    let commit: String?

    init(version: String, channel: NotchChannel, commit: String?) {
        self.version = version
        self.channel = channel
        self.commit = commit.flatMap(NotchUpdate.sha)
    }

    init(info: [String: Any]) {
        self.init(version: info["CFBundleShortVersionString"] as? String ?? "dev",
                  channel: (info["EclipseChannel"] as? String).flatMap(NotchChannel.init) ?? .stable,
                  commit: info["EclipseCommit"] as? String)
    }

    static let current = NotchBuild(info: Bundle.main.infoDictionary ?? [:])

    /// "0.1 · beta · 3c2a404", or "0.1 · stable · local build" without a commit.
    var summary: String {
        [version, channel.rawValue, commit.map { String($0.prefix(7)) } ?? "local build"].joined(separator: " · ")
    }
}

/// The outcome of one check, as Settings shows it.
enum NotchUpdateStatus: Equatable {
    case idle, checking, upToDate
    /// The newest commit of the channel, in full.
    case available(String)
    case failed(String)
}

/// The manual update check. Only a press of Check for updates sends anything: one GET to GitHub for the newest commit
/// on the channel's branch, without cookies or credentials. Updating runs the install command in Terminal.
@MainActor
final class NotchUpdate: ObservableObject {
    @Published private(set) var status = NotchUpdateStatus.idle
    let build: NotchBuild

    private static let session = URLSession(configuration: .ephemeral, delegate: NotchNoRedirects(), delegateQueue: nil)

    init(build: NotchBuild = .current) {
        self.build = build
    }

    func check() async {
        guard let commit = build.commit, status != .checking else { return }
        status = .checking
        do {
            let (data, response) = try await Self.session.data(for: Self.request(for: build.channel))
            status = Self.status(commit: commit, data: data, response: response)
        } catch {
            status = Self.status(for: error)
        }
    }

    /// Opens Terminal on a script that runs the install command. Opening a `.command` file needs no Automation
    /// permission, unlike telling Terminal to run a command.
    func install() {
        let folder = FileManager.default.temporaryDirectory.appending(path: "eclipse-update-\(UUID().uuidString)")
        let script = folder.appending(path: "Update Eclipse.command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(Self.script(for: build.channel).utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            status = .failed("Could not write the update script")
            return
        }
        if !NSWorkspace.shared.open(script) { status = .failed("Could not open Terminal") }
    }

    func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(build.channel.installCommand, forType: .string)
    }

    // MARK: Pure parts, driven by scripts/notch/NotchUpdateChecks.swift

    /// The lowercase SHA when `text` is a full 40 character commit SHA, else nil.
    nonisolated static func sha(_ text: String) -> String? {
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sha.count == 40 && sha.allSatisfy(\.isHexDigit) ? sha : nil
    }

    /// GitHub's answer to this media type is the bare SHA of the branch's newest commit.
    nonisolated static func request(for channel: NotchChannel) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/AndreiStolojan/Eclipse/commits/\(channel.branch)")!,
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github.sha", forHTTPHeaderField: "Accept")
        // GitHub refuses requests without a User-Agent; this one replaces the default, which names the macOS version.
        request.setValue("Eclipse", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    nonisolated static func status(commit: String, data: Data, response: URLResponse) -> NotchUpdateStatus {
        guard let http = response as? HTTPURLResponse else { return .failed("Could not reach GitHub") }
        switch http.statusCode {
        case 200:
            guard let latest = String(data: data, encoding: .utf8).flatMap(sha) else {
                return .failed("Unexpected answer from GitHub")
            }
            return latest == commit ? .upToDate : .available(latest)
        case 429:
            return .failed("GitHub rate limit, try again later")
        case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0":
            return .failed("GitHub rate limit, try again later")
        default:
            return .failed("GitHub answered \(http.statusCode)")
        }
    }

    nonisolated static func status(for error: Error) -> NotchUpdateStatus {
        guard let code = (error as? URLError)?.code else { return .failed("Could not reach GitHub") }
        return switch code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            .failed("Offline")
        case .timedOut: .failed("GitHub did not answer")
        default: .failed("Could not reach GitHub")
        }
    }

    nonisolated static func script(for channel: NotchChannel) -> String {
        """
        #!/bin/bash
        # Written by Eclipse's Check for updates. It builds and installs the newest \(channel.branch) commit.
        \(channel.installCommand)

        """
    }
}
