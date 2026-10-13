/// Reads a value again and again until it settles, for a gated test that waits
/// for work the library runs in a task of its own.
enum SettledValuePoll {
    /// The time between two reads, in milliseconds.
    static let readIntervalMilliseconds = 50

    /// The time between two reads.
    static let readInterval: Duration = .milliseconds(readIntervalMilliseconds)

    /// The value `read` gives once `isSettled` accepts it.
    ///
    /// The wait has no time limit. It ends when the value settles, or when the
    /// caller stops the test.
    ///
    /// - Parameters:
    ///   - read: Reads the value.
    ///   - isSettled: Tells if a value is the settled one.
    /// - Returns: The settled value.
    /// - Throws: `CancellationError` when the test is cancelled.
    static func value<Value: Sendable>(
        of read: () async -> Value, settledWhen isSettled: (Value) -> Bool
    ) async throws -> Value {
        while true {
            let value = await read()
            if isSettled(value) { return value }
            try await Task.sleep(for: readInterval)
        }
    }
}
