import Synchronization
import Testing

/// A wait with an upper limit. A regression that keeps the wait open fails
/// the test when the limit ends, and does not stop the suite.
///
/// The limit is not an order of events. A correct build ends each wait as
/// soon as the event comes. The limit is only the point where the test
/// stops to wait for an event that does not come.
enum BoundedWait {
    /// The default limit of one wait. It is long, because many suites run at
    /// the same time.
    static let limit: Duration = .seconds(60)

    /// The error of a wait whose limit ended first.
    struct Expired: Error, CustomStringConvertible {
        /// The limit of the wait.
        let limit: Duration

        /// The place of the wait in the test.
        let sourceLocation: SourceLocation

        /// What went wrong, and where.
        var description: String {
            "the wait at \(sourceLocation.fileName):\(sourceLocation.line) did not end inside its limit of \(limit)"
        }
    }

    /// The first result of one wait: the result of the task, or the end of the
    /// limit. A lock guards it, because two tasks race to give it.
    private final class Race<T: Sendable>: Sendable {
        /// The continuation of the waiter, until one result resumes it.
        private let continuation = Mutex<CheckedContinuation<T, any Error>?>(nil)

        /// Keeps `continuation`.
        ///
        /// - Parameter continuation: The continuation of the waiter.
        func arm(_ continuation: CheckedContinuation<T, any Error>) {
            self.continuation.withLock { $0 = continuation }
        }

        /// Resumes the waiter with `result`, when no result resumed it.
        ///
        /// - Parameter result: The result to give.
        /// - Returns: `true` when this result resumed the waiter.
        @discardableResult
        func resume(with result: Result<T, any Error>) -> Bool {
            guard let continuation = self.continuation.withLock({ $0.take() }) else { return false }
            continuation.resume(with: result)
            return true
        }
    }

    /// The value of `task`, or ``Expired`` when `limit` ends first. When the
    /// limit ends first, the wait cancels `task`, and does not wait for it to
    /// end.
    ///
    /// - Parameters:
    ///   - task: The task to wait for.
    ///   - limit: The upper limit of the wait.
    ///   - sourceLocation: The place of the wait, for the error.
    /// - Returns: The value of `task`.
    /// - Throws: The error of `task`, or ``Expired``.
    static func value<T: Sendable>(
        of task: Task<T, any Error>, within limit: Duration = limit,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> T {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.arm(continuation)
            let timer = Task {
                guard (try? await Task.sleep(for: limit)) != nil else { return }
                if race.resume(with: .failure(Expired(limit: limit, sourceLocation: sourceLocation))) {
                    task.cancel()
                }
            }
            Task {
                race.resume(with: await task.result)
                timer.cancel()
            }
        }
    }

    /// The value of `body`, or ``Expired`` when `limit` ends first.
    ///
    /// - Parameters:
    ///   - limit: The upper limit of the wait.
    ///   - sourceLocation: The place of the wait, for the error.
    ///   - body: The wait.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`, or ``Expired``.
    static func run<T: Sendable>(
        within limit: Duration = limit, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await value(of: Task { try await body() }, within: limit, sourceLocation: sourceLocation)
    }
}
