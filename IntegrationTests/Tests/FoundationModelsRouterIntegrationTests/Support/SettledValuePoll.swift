/// Reads a value again and again until it settles, for a gated test that waits
/// for work the library runs in a task of its own.
enum SettledValuePoll {
    /// How many times a poll reads the value before it stops.
    static let readLimit = 600

    /// The time between two reads, in milliseconds.
    static let readIntervalMilliseconds = 50

    /// The time between two reads.
    static let readInterval: Duration = .milliseconds(readIntervalMilliseconds)

    /// The value `read` gives once `isSettled` accepts it, or the value of one
    /// more read at the end of a bounded wait.
    ///
    /// The wait is bounded, so a value that never settles makes the assertion
    /// of the caller fail instead of making the test run without end.
    ///
    /// - Parameters:
    ///   - read: Reads the value.
    ///   - isSettled: Tells if a value is the settled one.
    /// - Returns: The settled value, or the last value read.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func value<Value: Sendable>(
        of read: () async -> Value, settledWhen isSettled: (Value) -> Bool
    ) async throws -> Value {
        for _ in 0..<readLimit {
            let value = await read()
            if isSettled(value) { return value }
            try await Task.sleep(for: readInterval)
        }
        return await read()
    }
}
