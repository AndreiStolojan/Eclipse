import Foundation

@main
struct NotchNoticeChecks {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) {
            precondition(value(), name)
            checks += 1
            print("PASS \(name)")
        }
        func notice(_ title: String, id: String? = nil) -> NotchNotice {
            NotchNotice(title: title, detail: nil, symbol: nil, tint: .white, id: id, progress: nil)
        }
        let now = ContinuousClock.now
        let date = Date(timeIntervalSince1970: 1_000)
        var notices = NotchNotices()
        notices.receive(notice("Backup failed", id: "pi.backup"), at: now, date: date)
        let first = notices.next!
        notices.consume(3, for: first.id)
        notices.receive(first.notice, at: now + .seconds(10), date: date + 10)
        check(notices.history.count == 1 && notices.history[0].received == date && notices.remaining == 5,
              "Identical repeats neither grow history nor restart the alert")
        notices.receive(notice("Build finished", id: "build"), at: now)
        notices.receive(notice("Backup recovered", id: "pi.backup"), at: now + .seconds(11))
        check(notices.next?.id == first.id && notices.next?.notice.title == "Backup recovered"
              && notices.waitingCount == 1 && notices.remaining == 5,
              "Recovery updates the active ID without losing its time or FIFO position")
        notices.consume(5, for: first.id)
        check(notices.next?.notice.title == "Build finished" && notices.history.count == 2,
              "Expiring an alert advances FIFO and keeps both history entries")
        notices.receive(notice("Build failed", id: "build"), at: now + .seconds(12))
        check(notices.waitingCount == 0 && notices.next?.notice.title == "Build failed",
              "A waiting ID is replaced rather than duplicated")
        notices.clearPending()
        notices.receive(notice("Build failed", id: "build"), at: now + .seconds(13))
        check(notices.next == nil, "An identical already-seen notice does not re-alert")
        notices.receive(notice("Build recovered", id: "build"), at: now + .seconds(14))
        check(notices.next?.notice.title == "Build recovered", "A changed previously-seen ID may alert again")
        notices.consume(2, for: notices.next!.id)
        let held = notices.remaining
        notices.prune(at: now + .seconds(30))
        check(notices.remaining == held, "Covered time does not spend the visible-time budget")
        notices.prune(at: now + .seconds(74))
        check(notices.next == nil && notices.history.count == 2, "Stale alerts expire at 60 seconds without deleting history")
        notices.receive(notice("During lock"), at: now, alert: false)
        check(notices.next == nil && notices.history.first?.notice.title == "During lock",
              "A locked or sleeping receiver can keep history without scheduling an alert")
        notices.receive(notice("During lock"), at: now)
        check(notices.history.count == 3 && notices.next == nil, "Identical notices without an ID also deduplicate")

        var replacing = NotchNotices()
        replacing.receive(notice("First", id: "first"), at: now)
        replacing.receive(notice("Waiting failed", id: "waiting"), at: now)
        replacing.receive(notice("Waiting recovered", id: "waiting"), at: now + .seconds(10))
        check(replacing.next?.notice.title == "First" && replacing.waitingCount == 1,
              "Replacing a waiting ID preserves FIFO and the number of alerts")
        replacing.dismissAlert()
        check(replacing.next?.notice.title == "Waiting recovered" && replacing.remaining == 8,
              "The updated waiting notice gets its original full visible-time budget")

        var flood = NotchNotices()
        for i in 0..<10 { flood.receive(notice("Notice \(i)", id: "check.\(i)"), at: now) }
        check(flood.waitingCount == 7 && flood.next?.notice.title == "Notice 0",
              "A burst is bounded to eight alerts and preserves the current alert")
        flood.dismissAlert()
        check(flood.next?.notice.title == "Notice 3" && flood.history.count == 10,
              "Overflow drops the oldest waiting alerts but leaves their history")
        for i in 10..<40 { flood.receive(notice("Notice \(i)", id: "check.\(i)"), at: now) }
        check(flood.history.count == 20 && flood.history.first?.notice.title == "Notice 39"
              && flood.waitingCount <= 7, "History and alert memory stay bounded under a sustained burst")
        let removed = flood.next!.id
        flood.remove(removed)
        check(!flood.history.contains { $0.id == removed } && flood.next?.id != removed,
              "Removing a history row also removes its pending alert")
        flood.clear()
        check(flood.history.isEmpty && flood.next == nil, "Clear empties history and queue")
        print("\(checks) notice checks passed")
    }
}
