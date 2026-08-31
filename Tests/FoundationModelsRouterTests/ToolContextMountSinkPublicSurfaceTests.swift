import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// The output a mount fixture in this file returns when no ``ToolContext`` is
/// bound around its call. No test here expects to read it: every call is made
/// through a mount, and a mount binds a context.
private let unboundToolOutput = "unbound"

/// Exercises ``ToolContext/mount(_:op:as:postingTo:)`` — the overload a caller
/// hands a sink of its own, so the events each mounted run posts reach that
/// sink under the run's own correlation.
///
/// The import is plain, with no `@testable`. The compiler is therefore the
/// first assertion in this file: the overload, and the ``OperationEventSink``
/// typealias the sink below conforms to, must both be public or nothing here
/// compiles. That is the assertion that matters, because the caller this
/// overload exists for lives in another package, where `@testable` is not
/// available to it.
///
/// The public surface publishes no way to build a ``ToolContext`` by hand, and
/// the mailbox behind one is not public either. So every mount below is made
/// where an outside caller makes it: inside a running tool, on the context that
/// tool reads out of ``ToolContext/current``. A scripted session drives that
/// tool, and the mounts happen in its body.
///
/// `.timeLimit` because two cases suspend on a barrier one mounted run must
/// reach. A regression that stops such a run from starting would suspend the
/// barrier forever and hang the whole `swift test` run, rather than failing the
/// test that caught it.
@Suite(
    "ToolContext.mount(postingTo:): a caller-supplied sink over the public surface",
    .timeLimit(.minutes(1))
)
struct ToolContextMountSinkPublicSurfaceTests {
    // MARK: - Vocabulary

    /// The temp-directory prefix every fixture in this suite is built with, so
    /// a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "ToolContextMountSinkPublicSurfaceTests"

    /// The label of the host run: the tool the session itself mounts, and the
    /// run every mount in this file is made from.
    private static let hostLabel = "host"

    /// The label of the run that mounts the two runs the re-stamp comparison
    /// reads. It is the MOUNTING run of that comparison.
    private static let mountingLabel = "mounting"

    /// The label of a run mounted through the default overload.
    private static let defaultMountedLabel = "default-mounted"

    /// The label of a run mounted through `postingTo:`.
    private static let sinkMountedLabel = "sink-mounted"

    /// The label of the first of the two concurrent runs.
    private static let firstConcurrentLabel = "first-concurrent"

    /// The label of the second of the two concurrent runs.
    private static let secondConcurrentLabel = "second-concurrent"

    /// The label of the run the background case mounts.
    private static let backgroundLabel = "background"

    /// How many bodies meet at the barrier of the concurrency case: the two
    /// mounted runs themselves.
    private static let concurrentRunCount = 2

    /// How many bodies meet at the barrier of the background case: the mounted
    /// run, and the run that mounted it — which arrives only after
    /// `call(arguments:)` has already handed its envelope back.
    private static let backgroundHandoffCount = 2

    /// The ceiling on the wait for the background run to settle, in seconds.
    private static let settlementDeadlineSeconds: Double = 30

    // MARK: - Fixtures

    /// A sink written the way a caller outside this package writes one: a
    /// conformance to the public ``OperationEventSink`` typealias, keeping
    /// every event in post order.
    ///
    /// `MountFixtures.RecordingSink` is the same shape and is deliberately not
    /// used here. It stands in a file that imports this module with
    /// `@testable`, so it proves nothing about what an outside caller can
    /// write. This conformance, in a plainly importing file, is itself one of
    /// the assertions.
    private actor RecordingSink: OperationEventSink {
        /// Every event posted to this sink, in post order.
        private(set) var events: [OperationEvent] = []

        func post(event: OperationEvent) {
            events.append(event)
        }
    }

    /// The completion tokens the runs of one test recorded, each under the
    /// label of the run that recorded it.
    ///
    /// A run's token is minted where the run opens, so a test learns each
    /// token from the run itself rather than deriving it. An actor, so a run
    /// that records from its own task cannot lose the write.
    private actor RunTokenLog {
        /// Every recorded token, keyed by the recording run's label.
        private(set) var tokens: [String: String] = [:]

        /// Records one run's own completion token.
        ///
        /// - Parameters:
        ///   - label: The recording run's label.
        ///   - token: That run's `completionToken`.
        func record(_ label: String, token: String) {
            tokens[label] = token
        }
    }

    /// A meeting point a fixed number of bodies must all reach before any of
    /// them goes on.
    ///
    /// Two cases need it, and neither can be written with a clock. The
    /// concurrency case needs both mounted runs in flight at one moment, so
    /// that the two correlations it compares belong to runs that really did
    /// overlap. The background case needs its mounted run held until after
    /// `call(arguments:)` has returned, so that the terminal event it then
    /// reads cannot have been posted before the call handed back.
    private actor CallBarrier {
        /// How many bodies must arrive before the barrier opens.
        private let partySize: Int

        /// How many have arrived so far.
        private var arrivedCount = 0

        /// The bodies suspended until the barrier opens.
        private var waiting: [CheckedContinuation<Void, Never>] = []

        /// Creates a barrier that opens on the `partySize`-th arrival.
        ///
        /// - Parameter partySize: How many bodies must arrive.
        init(partySize: Int) {
            self.partySize = partySize
        }

        /// Arrives at the barrier, and suspends until every other body has
        /// arrived too. The last arrival resumes them all and returns at once.
        func arriveAndWait() async {
            arrivedCount += 1
            guard arrivedCount < partySize else {
                let resumable = waiting
                waiting = []
                for continuation in resumable {
                    continuation.resume()
                }
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }
    }

    /// What the background case observed at the moment its mounted call
    /// returned, kept so the assertions can read it once the turn has ended.
    private actor ReturnSnapshot {
        /// The events the sink held when the mounted call handed back.
        private(set) var events: [OperationEvent] = []

        /// How many runs the session's run plane tracked at that moment.
        private(set) var trackedRunCount = 0

        /// Records what the mounting run saw when its mounted call returned.
        ///
        /// - Parameters:
        ///   - events: The sink's events at that moment.
        ///   - trackedRunCount: The run plane's depth at that moment.
        func record(events: [OperationEvent], trackedRunCount: Int) {
            self.events = events
            self.trackedRunCount = trackedRunCount
        }
    }

    /// Records the completion token of the run it is mounted as, posts one
    /// progress event carrying ``label`` as its detail, and returns.
    ///
    /// The detail is how an assertion picks this run's event out of a sink
    /// several runs post to; the recorded token is what that event's
    /// `correlationID` is then compared against.
    private struct RunIdentityTool: Tool {
        let name = "run_identity_tool"
        let description = "test-only tool that posts one progress event and records its own run's token"

        /// This run's label: the detail it posts, and the key it records its
        /// token under.
        let label: String

        /// Where this run records its own completion token.
        let log: RunTokenLog

        /// A barrier every call waits at once it has posted, or `nil` to
        /// return at once.
        let barrier: CallBarrier?

        func call(arguments: AmbientToolArguments) async throws -> String {
            guard let context = ToolContext.current else { return unboundToolOutput }
            await log.record(label, token: context.completionToken)
            await context.progress(label)
            await barrier?.arriveAndWait()
            return "ran: \(label)"
        }
    }

    /// Runs a body against the ``ToolContext`` bound around its own call, and
    /// records that context's completion token.
    ///
    /// This is how a mount reaches a real context over the public surface: the
    /// session mounts one of these, the scripted turn calls it, and its body
    /// then mounts whatever the test is about on the context it is handed.
    private struct MountingTool: Tool {
        /// The model-facing name a scripted call names to reach this tool.
        static let toolName = "mounting_tool"

        let name = MountingTool.toolName
        let description = "test-only tool that mounts another tool on its own running context"

        /// The key this run records its own token under.
        let label: String

        /// Where this run records its own completion token.
        let log: RunTokenLog

        /// What to do with the bound context.
        let body: @Sendable (ToolContext) async throws -> Void

        func call(arguments: AmbientToolArguments) async throws -> String {
            guard let context = ToolContext.current else { return unboundToolOutput }
            await log.record(label, token: context.completionToken)
            try await body(context)
            return "mounted: \(label)"
        }
    }

    // MARK: - Harness

    /// Drives one scripted turn that calls `host` exactly one time.
    ///
    /// - Parameter host: The tool the vended session mounts.
    /// - Throws: Whatever session vending or the turn throws.
    private static func driveTurn(calling host: MountingTool) async throws {
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-mounting-tool",
                        toolName: MountingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [host],
            tempDirPrefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        _ = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
    }

    /// The `correlationID` of the one event `detail` names.
    ///
    /// - Parameters:
    ///   - detail: The detail to match, exactly.
    ///   - events: The events the sink recorded.
    /// - Returns: That event's `correlationID`.
    /// - Throws: When no event in `events` carries `detail`.
    private static func correlationID(
        ofEventDetailed detail: String, in events: [OperationEvent]
    ) throws -> String {
        try #require(events.first { $0.detail == detail }).correlationID
    }

    /// The completion token the run `label` names recorded for itself.
    ///
    /// - Parameters:
    ///   - label: The run's label.
    ///   - tokens: Every recorded token.
    /// - Returns: That run's own `completionToken`.
    /// - Throws: When that run recorded nothing.
    private static func token(of label: String, in tokens: [String: String]) throws -> String {
        try #require(tokens[label])
    }

    // MARK: - The run's own correlation

    @Test("a run mounted with a caller-supplied sink posts under its own completion token")
    func callerSuppliedSinkSeesTheMountedRunsOwnCorrelation() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounted = context.mount(
                RunIdentityTool(label: Self.sinkMountedLabel, log: log, barrier: nil),
                postingTo: sink)
            _ = try await mounted.call(
                arguments: AmbientToolArguments(value: Self.sinkMountedLabel))
        }

        try await Self.driveTurn(calling: host)

        let events = await sink.events
        let tokens = await log.tokens
        let observed = try Self.correlationID(ofEventDetailed: Self.sinkMountedLabel, in: events)
        let ownToken = try Self.token(of: Self.sinkMountedLabel, in: tokens)
        let hostToken = try Self.token(of: Self.hostLabel, in: tokens)

        // The identity the run minted for itself, rather than the identity of
        // the run that mounted it.
        #expect(observed == ownToken)
        #expect(observed != hostToken)
    }

    // MARK: - The re-stamp, both ways round

    @Test("the default overload re-stamps onto the mounting run, and postingTo: does not")
    func theDefaultOverloadRestampsWhereTheSinkOverloadDoesNot() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        // Both mounts below are made on one context, of one tool, one call
        // apart. The overload is the only difference between them.
        let mountingBody: @Sendable (ToolContext) async throws -> Void = { context in
            let restamped = context.mount(
                RunIdentityTool(label: Self.defaultMountedLabel, log: log, barrier: nil))
            _ = try await restamped.call(
                arguments: AmbientToolArguments(value: Self.defaultMountedLabel))

            let direct = context.mount(
                RunIdentityTool(label: Self.sinkMountedLabel, log: log, barrier: nil),
                postingTo: sink)
            _ = try await direct.call(
                arguments: AmbientToolArguments(value: Self.sinkMountedLabel))
        }
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounting = context.mount(
                MountingTool(label: Self.mountingLabel, log: log, body: mountingBody),
                postingTo: sink)
            _ = try await mounting.call(
                arguments: AmbientToolArguments(value: Self.mountingLabel))
        }

        try await Self.driveTurn(calling: host)

        let events = await sink.events
        let tokens = await log.tokens
        let mountingToken = try Self.token(of: Self.mountingLabel, in: tokens)
        let restampedCorrelation = try Self.correlationID(
            ofEventDetailed: Self.defaultMountedLabel, in: events)
        let directCorrelation = try Self.correlationID(
            ofEventDetailed: Self.sinkMountedLabel, in: events)
        let restampedOwnToken = try Self.token(of: Self.defaultMountedLabel, in: tokens)
        let directOwnToken = try Self.token(of: Self.sinkMountedLabel, in: tokens)

        // The default overload's second stamp: the run posted under its own
        // token, and the mounting context re-stamped that onto its own before
        // the sink ever saw it. Both facts are needed — that the correlation
        // became the mounting run's, and that the run's own is gone.
        #expect(restampedCorrelation == mountingToken)
        #expect(restampedCorrelation != restampedOwnToken)

        // `postingTo:` skips that second stamp, because the sink IS the run's
        // upstream. The same tool, mounted on the same context, keeps its own
        // correlation.
        #expect(directCorrelation == directOwnToken)
        #expect(directCorrelation != mountingToken)
    }

    // MARK: - Two runs at one time

    @Test("two concurrent runs mounted with a caller-supplied sink are distinguishable")
    func twoConcurrentRunsAreDistinguishableByCorrelation() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let barrier = CallBarrier(partySize: Self.concurrentRunCount)
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let first = context.mount(
                RunIdentityTool(label: Self.firstConcurrentLabel, log: log, barrier: barrier),
                postingTo: sink)
            let second = context.mount(
                RunIdentityTool(label: Self.secondConcurrentLabel, log: log, barrier: barrier),
                postingTo: sink)

            // Neither call can return until both have posted, so the two
            // correlations compared below belong to runs that were in flight
            // at the same moment.
            async let firstRun = first.call(
                arguments: AmbientToolArguments(value: Self.firstConcurrentLabel))
            async let secondRun = second.call(
                arguments: AmbientToolArguments(value: Self.secondConcurrentLabel))
            _ = try await (firstRun, secondRun)
        }

        try await Self.driveTurn(calling: host)

        let events = await sink.events
        let tokens = await log.tokens
        let firstCorrelation = try Self.correlationID(
            ofEventDetailed: Self.firstConcurrentLabel, in: events)
        let secondCorrelation = try Self.correlationID(
            ofEventDetailed: Self.secondConcurrentLabel, in: events)

        // The assertion that cannot be written through the default overload:
        // mounted there, both events collapse onto the mounting run's one
        // token and the question cannot be asked.
        #expect(firstCorrelation != secondCorrelation)
        #expect(firstCorrelation == (try Self.token(of: Self.firstConcurrentLabel, in: tokens)))
        #expect(secondCorrelation == (try Self.token(of: Self.secondConcurrentLabel, in: tokens)))
    }

    // MARK: - The sink outlives the call

    @Test("a background mount keeps posting to the caller's sink after the call returned")
    func backgroundMountKeepsPostingAfterTheCallReturned() async throws {
        let sink = RecordingSink()
        let log = RunTokenLog()
        let handoff = CallBarrier(partySize: Self.backgroundHandoffCount)
        let snapshot = ReturnSnapshot()
        let host = MountingTool(label: Self.hostLabel, log: log) { context in
            let mounted = context.mount(
                RunIdentityTool(label: Self.backgroundLabel, log: log, barrier: handoff),
                as: ToolMount(mode: .background, timeout: nil),
                postingTo: sink)
            _ = try await mounted.call(
                arguments: AmbientToolArguments(value: Self.backgroundLabel))

            // The call has handed its envelope back and the run goes on behind
            // it, still held at the handoff. Read the sink here.
            let tracked = await context.backgroundRuns()
            await snapshot.record(events: await sink.events, trackedRunCount: tracked.count)

            // Let the run go, and stay in this turn until it has settled.
            await handoff.arriveAndWait()
            for run in tracked {
                _ = await context.wait(
                    completionToken: run.completionToken,
                    seconds: Self.settlementDeadlineSeconds)
            }
        }

        try await Self.driveTurn(calling: host)

        let atReturn = await snapshot.events
        // The read above is proven live by the two facts it did see: the run
        // plane tracked the launched run, and the launch's own progress event
        // had already reached the sink. Only then does the absence of a
        // terminal mean the run had not settled.
        #expect(await snapshot.trackedRunCount == 1)
        #expect(atReturn.contains { $0.kind == .progress })
        #expect(!atReturn.contains { $0.kind == .completed })

        let events = await sink.events
        let tokens = await log.tokens
        let terminal = try #require(events.first { $0.kind == .completed })
        let ownToken = try Self.token(of: Self.backgroundLabel, in: tokens)
        let hostToken = try Self.token(of: Self.hostLabel, in: tokens)

        // The sink was held for the life of the RUN: it took the terminal long
        // after the call that launched the run had returned, and that terminal
        // still carries the run's own correlation.
        #expect(terminal.correlationID == ownToken)
        #expect(terminal.correlationID != hostToken)
    }
}
