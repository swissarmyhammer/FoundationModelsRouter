import FoundationModels
import Synchronization
import Testing

// The probe of task ^8nqkten: does one call of `LanguageModelExecutor.respond`
// end before the SDK runs the tool body that call emitted? A per-model
// generation queue that holds one place for one executor call is safe only when
// the answer is yes. The probe lives in this support target because the unit
// target and the gated `IntegrationTests` package both drive it, and SwiftPM
// cannot share source between two test targets.

/// One boundary of a tool-using submission that ``PassBoundaryLog`` records.
public enum PassBoundary: Sendable, Equatable {
    /// An executor call started: one generation pass began.
    case executorEntered

    /// An executor call returned or threw: one generation pass ended.
    case executorExited

    /// The body of ``PassBoundaryProbeTool`` started.
    case toolBodyStarted

    /// The body of ``PassBoundaryProbeTool`` returned.
    case toolBodyEnded
}

/// One boundary and the instant it was recorded.
///
/// The instant is data for a printed measurement only. No check reads it: the
/// checks read the order of the events.
public struct PassBoundaryEvent: Sendable {
    /// The boundary that was crossed.
    public let boundary: PassBoundary

    /// When it was crossed.
    public let instant: ContinuousClock.Instant
}

/// The boundaries of one submission, in the order they were crossed.
///
/// The order is the order of the appends under one lock, so a test reads the
/// order from each event's position and two events at one clock instant never
/// tie. A `Mutex`, not an actor: the executor records its exit from a `defer`,
/// which cannot `await`.
///
/// A test waits for a state of the log with ``waitUntil(_:)``. Each record is
/// the event that wakes the wait, so the wait needs no clock and no poll.
public final class PassBoundaryLog: Sendable, Hashable {
    /// One task that waits until its condition holds.
    private struct Waiter {
        /// The condition the task waits for, over the boundaries so far.
        let condition: @Sendable ([PassBoundary]) -> Bool

        /// Resumes the task.
        let continuation: CheckedContinuation<Void, Never>
    }

    /// The events and the waiting tasks, under one lock.
    private struct State {
        /// The events so far, in the order they were recorded.
        var events: [PassBoundaryEvent] = []

        /// The tasks that wait for a condition that did not hold yet.
        var waiters: [Waiter] = []

        /// Every boundary so far, in the order it was crossed.
        var boundaries: [PassBoundary] { events.map(\.boundary) }
    }

    /// The events and the waiting tasks.
    private let state = Mutex(State())

    /// Creates a log that holds no event.
    public init() {}

    /// Records that `boundary` was crossed now, and resumes each waiter whose
    /// condition now holds.
    ///
    /// - Parameter boundary: The boundary that was crossed.
    public func record(_ boundary: PassBoundary) {
        let event = PassBoundaryEvent(boundary: boundary, instant: .now)
        let satisfied = state.withLock { state -> [Waiter] in
            state.events.append(event)
            let boundaries = state.boundaries
            let satisfied = state.waiters.filter { $0.condition(boundaries) }
            state.waiters.removeAll { $0.condition(boundaries) }
            return satisfied
        }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
    }

    /// Waits until `condition` holds for the boundaries of this log.
    ///
    /// The wait reads the boundaries at once, and again after each record.
    /// Nothing else ends the wait: a boundary that never comes keeps the test
    /// waiting, and a stack of the test process then shows the missing
    /// boundary.
    ///
    /// - Parameter condition: Tells whether the boundaries so far are the
    ///   boundaries that the test waits for.
    public func waitUntil(_ condition: @escaping @Sendable ([PassBoundary]) -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let holdsNow = state.withLock { state -> Bool in
                if condition(state.boundaries) { return true }
                state.waiters.append(Waiter(condition: condition, continuation: continuation))
                return false
            }
            if holdsNow {
                continuation.resume()
            }
        }
    }

    /// Every event so far, in the order it was recorded.
    public var recorded: [PassBoundaryEvent] { state.withLock { $0.events } }

    /// Every boundary so far, in the order it was crossed.
    public var boundaries: [PassBoundary] { recorded.map(\.boundary) }

    /// The position in ``recorded`` of one occurrence of `boundary`.
    ///
    /// - Parameters:
    ///   - boundary: The boundary to find.
    ///   - occurrence: Which occurrence, counted from zero.
    /// - Returns: The position, or `nil` when the log holds fewer occurrences.
    public func position(of boundary: PassBoundary, occurrence: Int) -> Int? {
        let positions = boundaries.indices.filter { boundaries[$0] == boundary }
        return positions.indices.contains(occurrence) ? positions[occurrence] : nil
    }

    /// How long each executor call ran, in call order: from each
    /// ``PassBoundary/executorEntered`` to the ``PassBoundary/executorExited``
    /// that follows it.
    public var passDurations: [Duration] {
        let events = recorded
        let entries = events.filter { $0.boundary == .executorEntered }
        let exits = events.filter { $0.boundary == .executorExited }
        return zip(entries, exits).map { entry, exit in entry.instant.duration(to: exit.instant) }
    }

    /// Compares two logs by identity, so a log keys the one executor that
    /// writes into it.
    ///
    /// - Parameters:
    ///   - lhs: One log.
    ///   - rhs: The other log.
    /// - Returns: `true` when both names are the same object.
    public static func == (lhs: PassBoundaryLog, rhs: PassBoundaryLog) -> Bool {
        lhs === rhs
    }

    /// Hashes this log by identity, matching ``==(_:_:)``.
    ///
    /// - Parameter hasher: The hasher to feed.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

// MARK: - The wrapper model

/// A `LanguageModel` that records when each call of the executor of `Wrapped`
/// starts and ends, and otherwise changes nothing.
///
/// Its executor calls the executor of `Wrapped` directly, on the same task and
/// over the same channel, as the Router's queued wrapper will. The two
/// ``PassBoundary`` events thus bracket exactly the span a queue place would
/// be held for.
public struct PassBoundaryProbeModel<Wrapped: LanguageModel>: LanguageModel {
    /// The model whose executor this wrapper times.
    public let wrapped: Wrapped

    /// The log each executor call records into.
    public let log: PassBoundaryLog

    /// Creates a wrapper that times the executor calls of `wrapped`.
    ///
    /// - Parameters:
    ///   - wrapped: The model to time.
    ///   - log: The log to record into.
    public init(wrapping wrapped: Wrapped, log: PassBoundaryLog) {
        self.wrapped = wrapped
        self.log = log
    }

    /// Passed through unchanged from the wrapped model.
    public var capabilities: LanguageModelCapabilities { wrapped.capabilities }

    /// The executor cache key: the wrapped model's own key and this log.
    public var executorConfiguration: Executor.Configuration {
        Executor.Configuration(wrapped: wrapped, log: log)
    }

    /// The executor that brackets each call of the wrapped executor with two
    /// ``PassBoundary`` events.
    public struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares by the wrapped model's own
        /// executor key and by the identity of the log.
        public struct Configuration: Sendable, Hashable {
            /// The wrapped model, passed to its executor on each call. Not part
            /// of the key beyond its own executor key.
            let wrapped: Wrapped

            /// The log each call records into.
            let log: PassBoundaryLog

            /// Equal when both wrap the same executor key and record into the
            /// same log.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when the keys and the logs match.
            public static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log
                    && lhs.wrapped.executorConfiguration == rhs.wrapped.executorConfiguration
            }

            /// Hashes the parts ``==(_:_:)`` compares.
            ///
            /// - Parameter hasher: The hasher to feed.
            public func hash(into hasher: inout Hasher) {
                hasher.combine(log)
                hasher.combine(wrapped.executorConfiguration)
            }
        }

        /// The model type this executor serves.
        public typealias Model = PassBoundaryProbeModel<Wrapped>

        /// The wrapped model's own executor, built once.
        private let inner: Wrapped.Executor

        /// The wrapped model and the log.
        private let configuration: Configuration

        /// Builds the wrapped model's executor once.
        ///
        /// - Parameter configuration: The wrapped model and the log.
        /// - Throws: What the wrapped executor's initializer throws.
        public init(configuration: Configuration) throws {
            inner = try Wrapped.Executor(configuration: configuration.wrapped.executorConfiguration)
            self.configuration = configuration
        }

        /// Records the start of the pass, runs the wrapped executor on this
        /// task over `channel`, and records the end of the pass on every exit.
        ///
        /// - Parameters:
        ///   - request: The generation request, passed through unchanged.
        ///   - model: This wrapper. Unread: the wrapped model arrives through
        ///     the configuration.
        ///   - channel: The channel the wrapped executor streams into.
        /// - Throws: What the wrapped executor throws.
        public func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: PassBoundaryProbeModel<Wrapped>,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            configuration.log.record(.executorEntered)
            defer { configuration.log.record(.executorExited) }
            try await inner.respond(to: request, model: configuration.wrapped, streamingInto: channel)
        }
    }
}

// MARK: - The tool

/// The arguments of ``PassBoundaryProbeTool``: the one `value` string the
/// scripted model's calls carry.
@Generable
public struct PassBoundaryProbeArguments {
    /// Any text. The tool echoes it back.
    @Guide(description: "Any short word to look up.")
    public let value: String
}

/// A tool whose body records two ``PassBoundary`` events, one at its start and
/// one at its end, with an optional hold between them.
///
/// The checks of ``PassBoundaryExpectations`` read the order of the events, not
/// the time between them. The pass that emits the tool call must end before
/// the body starts. Thus the order alone shows a pass that stays open across
/// the body, and the body needs no hold for that check.
public struct PassBoundaryProbeTool: FoundationModels.Tool {
    /// The model-facing name every probe script and prompt uses.
    public static let toolName = "probe"

    /// The model-facing name.
    public let name = Self.toolName

    /// The model-facing description.
    public let description = "Looks up a short word and returns what it found."

    /// The log the body records into.
    public let log: PassBoundaryLog

    /// What the body waits for between its two events.
    private let hold: @Sendable () async throws -> Void

    /// Creates a tool whose body waits for `hold` between its two events.
    ///
    /// - Parameters:
    ///   - log: The log to record into.
    ///   - hold: What the body waits for, for example a gate that the test
    ///     opens. The default returns at once.
    public init(log: PassBoundaryLog, hold: @escaping @Sendable () async throws -> Void = {}) {
        self.log = log
        self.hold = hold
    }

    /// Records the start, waits for the hold, records the end, and echoes the
    /// argument.
    ///
    /// - Parameter arguments: The call's arguments.
    /// - Returns: A line that carries the argument.
    /// - Throws: What the hold throws, for example `CancellationError`.
    public func call(arguments: PassBoundaryProbeArguments) async throws -> String {
        log.record(.toolBodyStarted)
        try await hold()
        log.record(.toolBodyEnded)
        return "probe found \(arguments.value)"
    }
}

// MARK: - The shared checks

/// The checks the unit suite and the gated suite both make on one submission's
/// ``PassBoundaryLog``.
public enum PassBoundaryExpectations {
    /// Checks that the pass that emitted the first tool call ended before the
    /// tool body ended, and states whether it also ended before the tool body
    /// started.
    ///
    /// The first check is the one a per-pass queue needs: a pass still open at
    /// the end of the tool body would hold its queue place across the body.
    /// The second is the best result: the pass released before the SDK even
    /// started the body.
    ///
    /// - Parameters:
    ///   - log: The log of the submission.
    ///   - sourceLocation: Where a failure is reported.
    /// - Throws: When the log holds no pass end or no tool body.
    public static func expectFirstPassEndsBeforeItsToolBody(
        in log: PassBoundaryLog, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let passEnd = try #require(
            log.position(of: .executorExited, occurrence: 0), sourceLocation: sourceLocation)
        let bodyStart = try #require(
            log.position(of: .toolBodyStarted, occurrence: 0),
            "the submission never ran the tool: \(log.boundaries)", sourceLocation: sourceLocation)
        let bodyEnd = try #require(
            log.position(of: .toolBodyEnded, occurrence: 0), sourceLocation: sourceLocation)
        #expect(
            passEnd < bodyEnd, "the pass stayed open across the tool body: \(log.boundaries)",
            sourceLocation: sourceLocation)
        #expect(
            passEnd < bodyStart, "the pass was still open when the tool body started: \(log.boundaries)",
            sourceLocation: sourceLocation)
    }

    /// Checks that the pass after the tool body started only after the body
    /// ended, so the tool output reached it.
    ///
    /// - Parameters:
    ///   - log: The log of the submission.
    ///   - sourceLocation: Where a failure is reported.
    /// - Throws: When the log holds no second pass or no tool body end.
    public static func expectNextPassStartsAfterToolBody(
        in log: PassBoundaryLog, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let bodyEnd = try #require(
            log.position(of: .toolBodyEnded, occurrence: 0), sourceLocation: sourceLocation)
        let nextPassStart = try #require(
            log.position(of: .executorEntered, occurrence: 1),
            "the submission made no pass after the tool: \(log.boundaries)", sourceLocation: sourceLocation)
        #expect(bodyEnd < nextPassStart, "\(log.boundaries)", sourceLocation: sourceLocation)
    }

    /// Reads every element of `stream` as soon as it comes.
    ///
    /// - Parameter stream: The stream to read.
    /// - Returns: How many elements the stream gave.
    /// - Throws: What the stream throws.
    public static func consume<Stream: AsyncSequence>(_ stream: Stream) async throws -> Int {
        var elementCount = 0
        for try await _ in stream {
            elementCount += 1
        }
        return elementCount
    }

    /// Reads every element of `stream`, and after each one waits until every
    /// pass that `log` saw start has ended: a consumer slower than any pass.
    ///
    /// The wait is on the pass boundaries, not on a clock (task ^v4zh807). A
    /// pass that holds its end until the consumer reads the next element
    /// never ends, so the wait never ends. A pass that a loaded machine makes
    /// slow only makes the wait longer.
    ///
    /// - Parameters:
    ///   - stream: The stream to read.
    ///   - log: The log the executor records each pass into.
    /// - Returns: How many elements the stream gave.
    /// - Throws: What the stream throws.
    public static func consumeAfterEachOpenPassEnds<Stream: AsyncSequence>(
        _ stream: Stream, log: PassBoundaryLog
    ) async throws -> Int {
        var elementCount = 0
        for try await _ in stream {
            elementCount += 1
            await log.waitUntil { hasNoOpenPass($0) }
        }
        return elementCount
    }

    /// Whether every pass in `boundaries` that started has also ended.
    ///
    /// - Parameter boundaries: The boundaries of one submission so far.
    /// - Returns: Whether they hold as many pass ends as pass starts.
    private static func hasNoOpenPass(_ boundaries: [PassBoundary]) -> Bool {
        let starts = boundaries.filter { $0 == .executorEntered }.count
        let ends = boundaries.filter { $0 == .executorExited }.count
        return starts == ends
    }
}
