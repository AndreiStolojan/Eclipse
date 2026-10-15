import Foundation

@main
struct NotchMessageChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
            print("PASS \(name)")
        }
        func parse(_ json: String) -> Result<NotchMessage, NotchRejection> { NotchMessage.parse(Data(json.utf8)) }
        func notice(_ json: String) -> NotchNotice? {
            guard case .success(.notify(let notice)) = parse(json) else { return nil }
            return notice
        }

        check(notice(#"{"type":"notify","title":"Build finished","detail":"42 s","symbol":"hammer.fill","tint":"green","id":"build","progress":0.4}"#)
              == NotchNotice(title: "Build finished", detail: "42 s", symbol: "hammer.fill", tint: .green, id: "build", progress: 0.4),
              "Full notify parses")
        check(notice(#"{"type":"notify","title":"Done","future":[1,2]}"#)
              == NotchNotice(title: "Done", detail: nil, symbol: nil, tint: .white, id: nil, progress: nil),
              "Minimal notify defaults to white and ignores unknown keys")
        check(parse(#"{"type":"dictation","state":"recording","level":0.42}"#)
              == .success(.dictation(NotchDictationUpdate(state: .recording, level: 0.42))), "Dictation parses")
        check(parse(#"{"type":"dictation","state":"idle"}"#) == .success(.dictation(NotchDictationUpdate(state: .idle, level: 0))),
              "Dictation level defaults to 0")

        check(notice(#"{"type":"notify","title":"  Line\none\tand‮two\u0007 ","detail":"   "}"#)?.title == "Line one andtwo"
              && notice(#"{"type":"notify","title":"x","detail":"   "}"#)?.detail == nil,
              "Line breaks become spaces, control and bidi characters go, blank detail is dropped")
        let long = String(repeating: "a", count: 38) + " bcd"
        check(notice(#"{"type":"notify","title":"\#(long)"}"#)?.title == String(repeating: "a", count: 38) + "…",
              "Title over 40 characters is cut with an ellipsis and no dangling space")
        check(notice(#"{"type":"notify","title":"x","detail":"\#(String(repeating: "é", count: 81))"}"#)?.detail
              == String(repeating: "é", count: 79) + "…", "Detail is cut at 80 characters, not bytes")
        check(notice(#"{"type":"notify","title":"x","progress":1.7}"#)?.progress == 1
              && notice(#"{"type":"notify","title":"x","progress":-2}"#)?.progress == 0
              && parse(#"{"type":"dictation","state":"recording","level":3}"#)
              == .success(.dictation(NotchDictationUpdate(state: .recording, level: 1))),
              "Progress and level clamp to 0...1")

        check(parse(#"{"type":"notify","title":"x""#) == .failure(.malformed), "Truncated JSON is rejected")
        check(parse(#"["notify"]"#) == .failure(.malformed), "Non-object JSON is rejected")
        check(parse(#"{"type":"notify","title":"x","progress":NaN}"#) == .failure(.malformed), "NaN progress is rejected")
        check(NotchNotice.validated(title: "x", progress: .infinity) == .failure(.invalid("progress")),
              "Infinite progress is rejected")
        check(NotchMessage.parse(Data([0x7B, 0xFF, 0x7D])) == .failure(.invalidUTF8), "Invalid UTF-8 is rejected")
        check(parse(#"{"type":"shout","title":"x"}"#) == .failure(.unknownType), "Unknown type is rejected")
        check(parse(#"{"title":"x"}"#) == .failure(.missing("type")) && parse(#"{"type":"notify"}"#) == .failure(.missing("title"))
              && parse(#"{"type":"dictation"}"#) == .failure(.missing("state")), "Missing fields are named")
        check(parse(#"{"type":"notify","title":" \n "}"#) == .failure(.invalid("title")), "Blank title is rejected")
        check(parse(#"{"type":"notify","title":42}"#) == .failure(.invalid("title")), "Wrong JSON type is rejected")
        for symbol in ["Hammer", "hammer..fill", ".hammer", "hammer.", "ham mer", "hämmer", String(repeating: "a", count: 65)] {
            check(parse(#"{"type":"notify","title":"x","symbol":"\#(symbol)"}"#) == .failure(.invalid("symbol")), "Bad symbol \(symbol)")
        }
        check(notice(#"{"type":"notify","title":"x","symbol":"\#(String(repeating: "a", count: 64))"}"#) != nil,
              "Symbol of 64 characters passes")
        check(parse(#"{"type":"notify","title":"x","tint":"mauve"}"#) == .failure(.invalid("tint")), "Unknown tint is rejected")
        for id in ["", "a b", "a/b", String(repeating: "a", count: 65)] {
            check(parse(#"{"type":"notify","title":"x","id":"\#(id)"}"#) == .failure(.invalid("id")), "Bad id '\(id)'")
        }
        check(parse(#"{"type":"dictation","state":"dreaming"}"#) == .failure(.invalid("state")), "Unknown dictation state is rejected")
        let padded = #"{"type":"notify","title":"x","pad":""# + String(repeating: " ", count: 4096) + #""}"#
        check(parse(padded) == .failure(.oversized), "Line over 4096 bytes is rejected")

        check(NotchReply.presenting(available: true).line == Data(#"{"type":"presenting","available":true}"#.utf8 + [0x0A])
              && NotchReply.presenting(available: false).line == Data(#"{"type":"presenting","available":false}"#.utf8 + [0x0A])
              && NotchReply.stop.line == Data(#"{"type":"stop"}"#.utf8 + [0x0A])
              && NotchReply.cancel.line == Data(#"{"type":"cancel"}"#.utf8 + [0x0A]), "Replies encode exactly")
        let sent = NotchNotice(title: "Tests/passed", detail: "3 \"quoted\"", symbol: "checkmark", tint: .teal, id: "ci", progress: 1)
        let line = NotchMessage.notify(sent).line
        check(String(decoding: line, as: UTF8.self)
              == #"{"detail":"3 \"quoted\"","id":"ci","progress":1,"symbol":"checkmark","tint":"teal","title":"Tests/passed","type":"notify"}"# + "\n"
              && NotchMessage.parse(line.dropLast()) == .success(.notify(sent)), "Notify encodes one line that parses back")

        var limit = NotchRateLimit()
        check((0..<60).allSatisfy { _ in limit.allow(at: 0) } && !limit.allow(at: 0), "Rate limit allows a burst of 60")
        check(limit.allow(at: 1_000_000_000 / 60 + 1) && !limit.allow(at: 1_000_000_000 / 60 + 1), "Rate limit refills at 60 per second")
        var levels = NotchRateLimit()
        check((0..<200).allSatisfy { levels.allow(at: UInt64($0) * 50_000_000) }, "20 Hz levels always pass")
        print("\(checks) message checks passed")
    }
}
