import Foundation

/// The update check without the network: build info from Info.plist, GitHub's answers, and the install command.
@main
struct NotchUpdateChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }
        let local = "3c2a404" + String(repeating: "a", count: 33)
        let newer = "9f8e7d6" + String(repeating: "b", count: 33)
        func answer(_ status: Int, _ body: String, _ headers: [String: String] = [:]) -> NotchUpdateStatus {
            let url = NotchUpdate.request(for: .beta).url!
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
            return NotchUpdate.status(commit: local, data: Data(body.utf8), response: response)
        }

        let beta = NotchBuild(info: ["CFBundleShortVersionString": "0.1", "EclipseChannel": "beta",
                                     "EclipseCommit": local.uppercased()])
        check(beta == NotchBuild(version: "0.1", channel: .beta, commit: local) && beta.summary == "0.1 · beta · 3c2a404",
              "A beta build shows its version, channel and short commit")
        let xcode = NotchBuild(info: ["CFBundleShortVersionString": "0.1", "EclipseChannel": "", "EclipseCommit": ""])
        check(xcode.commit == nil && xcode.channel == .stable && xcode.summary == "0.1 · stable · local build",
              "A build without a commit is a local stable build")
        check(NotchBuild(info: ["EclipseCommit": "3c2a404"]).commit == nil
              && NotchBuild(info: ["EclipseCommit": String(repeating: "g", count: 40)]).commit == nil,
              "Only a full hexadecimal SHA counts as a commit")

        let request = NotchUpdate.request(for: .beta)
        check(request.url?.absoluteString == "https://api.github.com/repos/AndreiStolojan/Eclipse/commits/beta"
              && NotchUpdate.request(for: .stable).url?.lastPathComponent == "main"
              && request.httpMethod == "GET" && request.httpBody == nil
              && request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.sha"
              && request.value(forHTTPHeaderField: "Authorization") == nil && !request.httpShouldHandleCookies,
              "The request asks GitHub for the channel's newest SHA and carries nothing else")

        check(answer(200, local + "\n") == .upToDate, "The same SHA is up to date")
        check(answer(200, newer) == .available(newer), "A different SHA is an update")
        check(answer(200, "<html>") == .failed("Unexpected answer from GitHub"), "A body that is not a SHA is an error")
        check(answer(403, "", ["X-RateLimit-Remaining": "0"]) == .failed("GitHub rate limit, try again later")
              && answer(429, "") == .failed("GitHub rate limit, try again later"), "Rate limits are named")
        check(answer(403, "") == .failed("GitHub answered 403") && answer(404, "") == .failed("GitHub answered 404"),
              "Other statuses are errors with their code")
        check(NotchUpdate.status(for: URLError(.notConnectedToInternet)) == .failed("Offline")
              && NotchUpdate.status(for: URLError(.timedOut)) == .failed("GitHub did not answer"),
              "Offline and timeouts are named")

        check(NotchChannel.stable.installCommand
              == "curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Eclipse/main/install.sh | bash"
              && NotchChannel.beta.installCommand
              == "curl -fsSL https://raw.githubusercontent.com/AndreiStolojan/Eclipse/main/install.sh | bash -s -- --beta",
              "Each channel installs from main's install.sh, beta with --beta")
        check(NotchUpdate.script(for: .beta).hasPrefix("#!/bin/bash\n")
              && NotchUpdate.script(for: .beta).contains("\n" + NotchChannel.beta.installCommand + "\n"),
              "The Terminal script runs the channel's install command")
        print("\(checks) update checks passed")
    }
}
