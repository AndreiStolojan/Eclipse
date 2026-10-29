import Foundation

/// One child process run to completion within a deadline that holds. Both pipes drain while the child writes, so
/// neither fills and stalls it. At the deadline, or on `stop()` from another thread, the child gets SIGTERM and a
/// second later SIGKILL. Once it exited, its output is read for at most a second more, so a descendant that kept a
/// pipe open cannot hold the caller. A stop before launch means it never starts.
final class NotchProcess: @unchecked Sendable {
    struct Outcome {
        let status: Int32
        let output: Data
        let errors: Data
        /// Ended by a signal, as after `stop()` or the deadline.
        let signalled: Bool
    }

    enum Failure: Error { case cancelled }

    private let process = Process()
    private let lock = NSLock()
    private var stopped = false
    private let exited = DispatchSemaphore(value: 0)

    init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
    }

    /// Blocks until the child exits, at the latest about `timeout` plus two seconds after it starts.
    func run(timeout: TimeInterval) throws -> Outcome {
        let output = Drain(), errors = Drain()
        process.standardOutput = output.pipe
        process.standardError = errors.pipe
        process.terminationHandler = { [exited] _ in exited.signal() }
        try lock.withLock {
            guard !stopped else { throw Failure.cancelled }
            try process.run()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            stop()
            exited.wait()
        }
        let drained = DispatchTime.now() + 1
        return Outcome(status: process.terminationStatus, output: output.collected(by: drained),
                       errors: errors.collected(by: drained), signalled: process.terminationReason == .uncaughtSignal)
    }

    /// Terminates the child, killing it a second later if it ignores that.
    func stop() {
        lock.withLock {
            stopped = true
            guard process.isRunning else { return }
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                lock.withLock { if process.isRunning { kill(pid, SIGKILL) } }
            }
        }
    }

    /// A pipe read as data arrives, until end of file or `collected(by:)`.
    private final class Drain: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private let ended = DispatchSemaphore(value: 0)

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [lock, ended, weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    ended.signal()
                } else {
                    lock.withLock { self?.data.append(chunk) }
                }
            }
        }

        /// What arrived until end of file, or until `deadline` while something still holds the pipe open.
        func collected(by deadline: DispatchTime) -> Data {
            _ = ended.wait(timeout: deadline)
            pipe.fileHandleForReading.readabilityHandler = nil
            return lock.withLock { data }
        }
    }
}
