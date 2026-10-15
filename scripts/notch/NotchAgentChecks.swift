import Foundation

/// T3 Code's thread states as the notch reads them: the phase mapping, which changes alert, and the commands sent
/// back. The JSON is trimmed from real `orchestration.subscribeShell` values of T3 Code 0.0.46.
@main
struct NotchAgentChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) {
            precondition((try? condition()) == true, name)
            checks += 1
            print("PASS \(name)")
        }
        func shell(_ id: String = "t1", status: String = "completed", run: String = "run:1", extra: String = "") throws -> T3ThreadShell {
            let json = """
                {"id":"\(id)","projectId":"p1","title":"Quick Peek","branch":"feat/9","status":"\(status)",
                 "activityRunStatus":null,"latestRunId":"\(run)","updatedAt":"2026-10-05T09:11:40.092Z",
                 "archivedAt":null,"deletedAt":null,
                 "modelSelection":{"model":"claude-opus-5-5"},"unknownField":[1,2]\(extra)}
                """
            return try JSONDecoder().decode(T3ThreadShell.self, from: Data(json.utf8))
        }
        func item(_ json: String) throws -> T3ShellItem { try JSONDecoder().decode(T3ShellItem.self, from: Data(json.utf8)) }

        check(try shell().phase == .done, "A completed run is Done")
        check(try shell(status: "running").phase == .running && shell(status: "waiting").phase == .running, "Running and waiting run")
        check(try shell(extra: #","pendingRuntimeRequest":{"id":"r1","kind":"user_input"}"#).phase == .input, "A question is Input")
        check(try shell(extra: #","pendingRuntimeRequest":{"id":"r1","kind":"command"}"#).phase == .approval, "A command waits for approval")
        check(try shell(status: "running", extra: #","pendingRuntimeRequest":{"id":"r1","kind":"auth_refresh"}"#).phase == .running,
              "An auth refresh is not the user's to approve")
        check(try shell(extra: #","hasActionableProposedPlan":true"#).phase == .plan, "A plan ready is Plan")
        check(try shell(status: "failed", extra: #","lastErrorClass":"usage_limit""#).phase == .limited, "A usage limit is Limit, not Failed")
        check(try shell(status: "failed").phase == .failed && shell(status: "interrupted").phase == .stopped, "Failed and Stopped")
        check(try shell(extra: #","pendingBackgroundTasks":[{"kind":"subagent"}]"#).phase == .running,
              "Subagents still working hold a finished run, as in T3")
        check(try shell(extra: #","pendingBackgroundTasks":[{"kind":"command"}]"#).phase == .done, "A dev server left running does not")
        check(try !shell(extra: #","lineage":{"relationshipToParent":"subagent"}"#).listed, "Subagent threads stay off the list")
        check(try shell(status: "something-new").phase == .idle, "An unknown status reads as idle")
        check(T3Date.parse("2026-10-05T09:11:40.092Z") != nil && T3Date.parse("2026-10-05T09:11:40Z") != nil, "T3's dates parse")

        let snapshot = #"{"kind":"snapshot","snapshot":{"threads":[{"id":"t1","projectId":"p1","title":"A","status":"running","updatedAt":"2026-10-05T09:00:00Z","latestRunId":"run:1"},{"broken":true}],"archivedThreads":[],"projects":[{"id":"p1","title":"Eclipse"}]}}"#
        var tracker = NotchAgentTracker()
        check(try tracker.apply(item(snapshot)).isEmpty && tracker.threads["t1"]?.project == "Eclipse",
              "The first snapshot only records, and a malformed thread is skipped")
        check(try tracker.apply(item(#"{"kind":"snapshot","snapshot":{"threads":[],"archivedThreads":[],"projects":[{"id":"p1","title":"Renamed"}]},"resolvedRepositoryIdentityRoots":["/x"]}"#)).isEmpty
              && tracker.threads["t1"]?.project == "Renamed", "A project refresh renames without emptying the list")
        let done = #"{"kind":"thread.updated","sequence":2,"location":"active","thread":{"id":"t1","projectId":"p1","title":"A","status":"completed","updatedAt":"2026-10-05T09:01:00Z","latestRunId":"run:1"}}"#
        let alerts = try tracker.apply(item(done))
        check(alerts.count == 1 && alerts.first?.thread.phase == .done, "Finishing alerts Done")
        check(try tracker.apply(item(done)).isEmpty, "The same run alerts once")
        check(try tracker.apply(item(done.replacingOccurrences(of: "run:1", with: "run:2"))).count == 1, "A later run alerts again")
        let settled = done.replacingOccurrences(of: "run:1", with: "run:3")
            .replacingOccurrences(of: #""latestRunId""#, with: #""settledOverride":"settled","latestRunId""#)
        check(try tracker.apply(item(settled)).isEmpty && tracker.list(at: .now).isEmpty,
              "A settled thread leaves the list and does not alert")
        let snoozed = done.replacingOccurrences(of: "run:1", with: "run:4")
            .replacingOccurrences(of: #""latestRunId""#, with: #""snoozedUntil":"2999-01-01T00:00:00Z","latestRunId""#)
        check(try tracker.apply(item(snoozed)).isEmpty && tracker.list(at: .now).isEmpty, "So does a snoozed one")
        check(tracker.list(at: T3Date.parse("2999-01-02T00:00:00Z")!).count == 1, "and it comes back when the snooze ends")
        check(try tracker.apply(item(#"{"kind":"thread.removed","sequence":3,"location":"active","threadId":"t1"}"#)).isEmpty
              && tracker.threads.isEmpty, "A removed thread leaves")
        check(try tracker.apply(item(#"{"kind":"something.new"}"#)).isEmpty, "An unknown stream value is ignored")

        let base = try shell().thread(projects: [:])
        let date = { (text: String) in T3Date.parse(text)! }
        var woke = base
        woke.snoozedUntil = date("2026-10-05T15:00:00Z")
        woke.snoozedAt = date("2026-10-05T12:00:00Z")
        check(woke.snoozed(at: date("2026-10-05T14:00:00Z")) && woke.shownPhase(at: date("2026-10-05T16:00:00Z")) == .woke,
              "A thread back from its snooze reads Woke")
        woke.lastVisited = date("2026-10-05T15:30:00Z")
        check(woke.shownPhase(at: date("2026-10-05T16:00:00Z")) == .done, "Opening it in T3 dismisses Woke")
        var early = base
        early.snoozedUntil = date("2026-10-06T09:00:00Z")
        early.snoozedAt = date("2026-10-05T12:00:00Z")
        early.runCompleted = date("2026-10-05T13:00:00Z")
        check(!early.snoozed(at: date("2026-10-05T14:00:00Z")) && early.shownPhase(at: date("2026-10-05T14:00:00Z")) == .woke,
              "A run finishing during the snooze wakes the thread early")
        var wakes = NotchAgentTracker()
        _ = try wakes.apply(item(#"{"kind":"snapshot","snapshot":{"threads":[{"id":"s","projectId":"p","title":"S","status":"completed","updatedAt":"2026-10-05T09:00:00Z","snoozedUntil":"2026-10-05T15:00:00Z","snoozedAt":"2026-10-05T12:00:00Z"}],"archivedThreads":[],"projects":[]}}"#))
        check(wakes.nextWake(after: date("2026-10-05T14:00:00Z")) == date("2026-10-05T15:00:00Z"), "The client sleeps until the next snooze ends")
        check(wakes.woken(after: date("2026-10-05T14:00:00Z"), through: date("2026-10-05T15:00:01Z")).first?.word == "Woke"
              && wakes.woken(after: date("2026-10-05T15:00:01Z"), through: date("2026-10-05T16:00:00Z")).isEmpty,
              "A snooze ending alerts Woke once")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let monday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10))!
        let labels = NotchSnoozeChoice.choices(at: monday, calendar: calendar).map(\.label)
        check(labels == ["1 h", "3 h", "Evening", "Tomorrow", "Monday"], "T3's snooze choices on a Monday morning")
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 17, minute: 30))!
        check(NotchSnoozeChoice.choices(at: sunday, calendar: calendar).map(\.label) == ["1 h", "3 h", "Tomorrow"],
              "No evening within the hour, and no Monday when it is tomorrow")
        let snooze = T3Command.snooze(threadID: "t", until: monday).payload
        check(snooze["type"] as? String == "thread.snooze" && (snooze["snoozedUntil"] as? String)?.hasSuffix("Z") == true
              && T3Date.parse(snooze["snoozedUntil"] as? String ?? "") == monday, "Snooze sends T3's command with a UTC time")
        check(try shell(status: "queued").phase == .idle, "A queued run is not running yet, as in T3")

        var alert = NotchAgentAlert(thread: try shell().thread(projects: [:]))
        alert.merge(NotchAgentAlert(thread: try shell("t2").thread(projects: [:])))
        check(alert.word == "2 Done", "Two threads done at once read as one alert")
        alert.merge(NotchAgentAlert(thread: try shell("t3", extra: #","pendingRuntimeRequest":{"id":"r","kind":"user_input"}"#).thread(projects: [:])))
        check(alert.word == "Input", "A different state replaces the count")

        let answer = T3Command.answer(threadID: "t1", requestID: "r1", answers: ["q1": ["A"], "q2": ["B", "C"]], multi: ["q2"]).payload
        let answers = answer["answers"] as? [String: Any]
        check(answer["type"] as? String == "runtime-request.respond" && answers?["q1"] as? String == "A"
              && answers?["q2"] as? [String] == ["B", "C"], "One choice sends a string, a multiple choice a list, keyed by question")
        check(T3Command.decide(threadID: "t1", requestID: "r1", decision: "accept").payload["decision"] as? String == "accept",
              "An approval sends T3's decision")

        let frame = T3Frame.parse(Data(#"{"_tag":"Chunk","requestId":"1","values":[{"kind":"synchronized"}]}"#.utf8))
        var chunked = false
        if case .chunk(let id, let values) = frame { chunked = id == "1" && values.count == 1 }
        check(chunked, "A chunk keeps its request and values")
        var succeeded = false
        if case .exit(let id, let success, _) = T3Frame.parse(Data(#"{"_tag":"Exit","requestId":"2","exit":{"_tag":"Success","value":{}}}"#.utf8)) {
            succeeded = id == "2" && success
        }
        check(succeeded, "A successful exit reads as success")

        let detail = try JSONDecoder().decode(T3ThreadSnapshot.self, from: Data("""
            {"projection":{"runs":[{"id":"run:2"}],"turnItems":[
             {"type":"assistant_message","status":"completed","runId":"run:1","text":"Earlier"},
             {"type":"file_change","status":"completed","runId":"run:2","fileName":"/a/NotchView.swift"},
             {"type":"command_execution","status":"running","runId":"run:2","input":"scripts/check.sh\\nmore"},
             {"type":"user_input_request","status":"pending","runId":"run:2","requestId":"r9","questions":[{"id":"q","header":"Layout","question":"Which?","options":[{"label":"A","description":"","value":"a"}]}]}
            ]}}
            """.utf8)).detail(pendingRequest: "r9")
        let pictured = try JSONDecoder().decode(T3ThreadSnapshot.self, from: Data("""
            {"projection":{"runs":[{"id":"run:1"}],"turnItems":[
             {"type":"assistant_message","status":"completed","runId":"run:1","ordinal":3,"text":"Here:\\n![Peek](/tmp/a.png) and ![](file:///tmp/b%20c.png) ![web](https://x.y/z.png)"},
             {"type":"user_message","status":"completed","runId":"run:1","ordinal":1,"attachments":[{"type":"image","id":"i1","name":"IMG.jpg"},{"type":"file","id":"f1"}]}
            ]}}
            """.utf8)).detail(pendingRequest: nil)
        check(pictured.images == [.file(path: "/tmp/b c.png", name: "b c.png"), .file(path: "/tmp/a.png", name: "Peek"),
                                  .attachment(id: "i1", name: "IMG.jpg")],
              "The page collects the agent's local images and the user's, newest first, without web images or other files")
        check(NotchMarkdownBlock.parse("Before\n\n![Peek](/tmp/a.png)\n\nAfter") == [.paragraph("Before"), .paragraph("After")],
              "An image on its own line leaves the text for the strip")
        check(NotchAgentImage.references(in: "![a](/Users/p/Screenshot%202026.png) ![b](</Users/p/My Shots/b.png>) ![c](/tmp/c.png \"t\")")
              == [.file(path: "/Users/p/Screenshot 2026.png", name: "a"), .file(path: "/Users/p/My Shots/b.png", name: "b"),
                  .file(path: "/tmp/c.png", name: "c")],
              "Image paths with encoded spaces, angle brackets or a title are found")
        check(NotchMarkdownBlock.parse("| a |\n|---|\n| - |") == [.table([["a"], ["-"]])], "A first row of dashes is content")
        check(NotchMarkdownBlock.parse("![diagram](https://x.y/d.png)") == [.paragraph("[diagram](https://x.y/d.png)")],
              "A web image stays in the text as a link")
        check(NotchMarkdownBlock.parse("| a | b |\r\n|---|---|\r\n| `x \\| y` | - |\r\n| - | - |\r\n\r\n* * *\r\n~~~\r\n# not a heading\r\n~~~")
              == [.table([["a", "b"], ["`x | y`", "-"], ["-", "-"]]), .code("# not a heading")],
              "CRLF, escaped pipes, rows of dashes, spaced rules and ~~~ fences")
        check(detail.message == nil && detail.lastMessage == "Earlier" && detail.files == 1,
              "A run that has said nothing yet shows no reply of its own; the earlier one is kept for a finished thread")
        let blocks = NotchMarkdownBlock.parse("""
            ## Luna pe `low`

            Testul anterior era deja pe `low`.
            Am mai rulat variante:

            | Configurație | Timp |
            |---|---|
            | `low` | 4,7 s |

            - **Codex** e un agent.
              Continuare.
            2. Lipești imediat.
            ```
            codex app-server
            ```
            """)
        check(blocks == [.heading("Luna pe `low`"), .paragraph("Testul anterior era deja pe `low`. Am mai rulat variante:"),
                         .table([["Configurație", "Timp"], ["`low`", "4,7 s"]]), .item(marker: "•", text: "**Codex** e un agent. Continuare."),
                         .item(marker: "2.", text: "Lipești imediat."), .code("codex app-server")],
              "A reply's Markdown reads as headings, paragraphs, tables, list items and code")
        var answered = false
        if case .questions(let id, let questions) = detail.request { answered = id == "r9" && questions.first?.options.first?.answer == "a" }
        check(answered, "An option answers with its value when T3 gives one")
        // The token only goes to T3's server on this Mac.
        check(NotchT3Origin.loopback("http://127.0.0.1:3773")?.absoluteString == "http://127.0.0.1:3773"
              && NotchT3Origin.loopback("http://localhost:3773/")?.absoluteString == "http://localhost:3773"
              && NotchT3Origin.loopback("http://[::1]:3773") != nil, "Loopback origins with a port are accepted")
        check(["https://example.com:3773", "http://example.com:3773", "http://127.0.0.1", "ws://127.0.0.1:3773",
               "http://user:pass@127.0.0.1:3773", "http://127.0.0.1:3773/../evil", "http://127.0.0.1:3773/api",
               "http://127.0.0.1:3773?next=https://example.com", "http://127.0.0.1:3773#x", "http://127.0.0.1.example.com:3773",
               "http://localhost.:3773", "http://127.0.0.2:3773", "file:///tmp/t3.sock", "", "127.0.0.1:3773",
               "http://127.0.0.1:0", "http://127.0.0.1:70000"].allSatisfy { NotchT3Origin.loopback($0) == nil },
              "Remote hosts, other schemes, a missing port, user info, paths, queries and fragments are refused")
        print("\(checks) agent checks passed")
    }
}
