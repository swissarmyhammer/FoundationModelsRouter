import Synchronization

/// The tool calls of one session that are in flight now, and the runs that
/// these calls wait for.
///
/// A foreground cancel (``RoutedSession/cancelForeground()``) must stop the
/// runs that a tool call still waits for, and must not stop the runs that
/// went to the background. The run plane of Extras lists each open run, but
/// it does not tell whether a call still waits for the run: the number of
/// waits of a run is internal to Extras. So the session tells it itself.
///
/// A run is **inline** from the open record of its call to the end of that
/// call. A run is **detached** when its call ended while the run is still
/// open: the call gave the pending envelope to the model, and the run goes on
/// in the background. The call ends at the end of its settle period, at the
/// end of its run, or at a cancel of the model call.
///
/// The model call binds the tracker of its session (``current``) around each
/// tool call (``ModelCallToolChecks/bound(_:)``). ``SessionCheckedTool`` wraps
/// the tool call in ``run(_:)``, which opens one ``Call`` and binds it
/// (``currentCall``). The open record of a run arrives from inside that call
/// (``RoutedSessionActor/deliver(invocation:)``), and it names the run in the
/// call (``noteRun(token:)``). The task of a run body keeps the binding of
/// its call, so a record that arrives after the call ended finds an ended
/// call and names no run.
final class ForegroundToolCalls: Sendable {
    /// One tool call that is in flight.
    final class Call: Sendable {
        /// What the lock holds.
        private struct State {
            /// The completion tokens of the runs that the call opened, in
            /// order.
            var runTokens: [String] = []

            /// Whether the call ended. An ended call names no more runs.
            var isEnded = false
        }

        /// The state of the call.
        private let state = Mutex(State())

        /// The completion tokens of the runs that the call opened.
        var runTokens: [String] {
            state.withLock { $0.runTokens }
        }

        /// Names a run that the call opened. A call that ended names none.
        ///
        /// - Parameter token: The completion token of the run.
        func noteRun(token: String) {
            state.withLock { state in
                guard !state.isEnded else { return }
                state.runTokens.append(token)
            }
        }

        /// Marks the call as ended.
        func end() {
            state.withLock { $0.isEnded = true }
        }
    }

    /// The tracker of the model call that the current task runs in, or `nil`
    /// outside a model call.
    @TaskLocal static var current: ForegroundToolCalls?

    /// The tool call that the current task runs in, or `nil` outside a tool
    /// call. The task of a run body that a call started keeps this value.
    @TaskLocal static var currentCall: Call?

    /// The calls in flight, with the key that removes each one.
    private let calls = Mutex<[Int: Call]>([:])

    /// The key of the next call.
    private let nextKey = Mutex(0)

    /// Runs one tool call as a call in flight of the tracker of the model
    /// call. With no tracker, `body` runs alone.
    ///
    /// - Parameter body: The tool call.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    static func run<Result>(_ body: () async throws -> Result) async throws -> Result {
        guard let tracker = current else { return try await body() }
        let (key, call) = tracker.begin()
        defer { tracker.end(call, key: key) }
        return try await $currentCall.withValue(call) { try await body() }
    }

    /// Names a run that the current tool call opened, when there is one.
    ///
    /// - Parameter token: The completion token of the run.
    static func noteRun(token: String) {
        currentCall?.noteRun(token: token)
    }

    /// The completion tokens of the runs that a call in flight opened: the
    /// runs that a call waits for now.
    var inlineRunTokens: [String] {
        calls.withLock { Array($0.values) }.flatMap(\.runTokens)
    }

    /// Opens one call.
    ///
    /// - Returns: The key and the call.
    private func begin() -> (key: Int, call: Call) {
        let key = nextKey.withLock { next in
            defer { next += 1 }
            return next
        }
        let call = Call()
        calls.withLock { $0[key] = call }
        return (key, call)
    }

    /// Ends one call, and takes it off the calls in flight.
    ///
    /// - Parameters:
    ///   - call: The call.
    ///   - key: The key that ``begin()`` gave.
    private func end(_ call: Call, key: Int) {
        call.end()
        calls.withLock { _ = $0.removeValue(forKey: key) }
    }
}
