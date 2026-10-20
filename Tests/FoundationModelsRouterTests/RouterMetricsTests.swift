import Foundation
import FoundationModelsExtras
import Metrics
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The metrics half of the telemetry vocabulary (``RouterTelemetry``): each
/// metric the router records through swift-metrics, with its name, its
/// dimensions and its value.
///
/// Each test runs in a `TelemetryCapture`, which binds a `TestMetrics` factory
/// for its task. A session pump is a detached task, so each test gives the
/// factory of the capture to its sessions as their explicit factory
/// (``RoutedSession/useCaptureMetrics(for:)``). A time value is only checked
/// to be recorded and not negative. The calls of the paced answer wait a
/// little, so the session sees the first token of each call, and no test
/// reads the length of a wait.
@Suite("The router records its metrics through swift-metrics with the names of its vocabulary")
struct RouterMetricsTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "RouterMetricsTests"

    /// The prompt of the metered tool-loop answer. No metric may carry it.
    private static let meteredPrompt = "look things up, then tell me what you found"

    /// The scripted usage of the three generation calls of the metered answer.
    private static let meteredCalls = [
        MeteredGenerationCall(tokensIn: 100, tokensOut: 30, tokensCached: 0),
        MeteredGenerationCall(tokensIn: 200, tokensOut: 50, tokensCached: 130),
        MeteredGenerationCall(tokensIn: 300, tokensOut: 70, tokensCached: 250),
    ]

    /// The sum of the cached fed tokens of ``meteredCalls``: 0 + 130 + 250.
    private static let meteredTokensCached: Int64 = 380

    /// The sum of the fed tokens of ``meteredCalls``: 100 + 200 + 300.
    private static let meteredTokensIn: Int64 = 600

    /// The sum of the generated tokens of ``meteredCalls``: 30 + 50 + 70.
    private static let meteredTokensOut: Int64 = 150

    /// The working context of the metered session.
    private static let meteredContextTokens = 1_000

    /// The prompt of the answer that holds the worker of the queue.
    private static let holdingPrompt = "the holding message of the metric test"

    /// The prompts of the messages that wait behind the holding answer.
    private static let waitingPrompts = [
        "the first waiting message of the metric test",
        "the second waiting message of the metric test",
    ]

    /// The prompt of the answer that triggers an automatic compaction: the
    /// answer after the warm-up.
    private static let triggeringPrompt = "message \(AutoCompactionFixtures.answerCount)"

    /// The name of the recorder of the depth of the mail queue of a session.
    private static let queueDepthName = "FoundationModelsRouter.session.queue_depth"

    /// The name of the counter of the cancelled mail.
    private static let cancelledMailName = "FoundationModelsRouter.mail.cancelled"

    /// The name of the timer of the pause of the mail queue for a compaction.
    private static let pauseDurationName = "FoundationModelsRouter.mail_queue.pause_duration"

    /// The name of the gauge of the bytes that the models of the pool use.
    private static let residentBytesName = "FoundationModelsRouter.model_pool.resident_bytes"

    /// Tells whether a feed of a session reported that a submission of that
    /// session waits in the queue of its model.
    ///
    /// - Parameter events: The events of the feed so far.
    /// - Returns: `true` when the events contain
    ///   ``SessionEvent/submissionQueued(_:)``.
    private static func containsQueuedSubmission(_ events: [SessionEvent]) -> Bool {
        events.contains { event in
            guard case .submissionQueued = event else { return false }
            return true
        }
    }

    /// Waits until the holding answer started its pass in the model of
    /// `fixture`, or until `holding` ended (rule T1).
    ///
    /// In a test that passes, the latch of `fixture` holds the pass in the
    /// model, so the holding answer cannot end before its pass started.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose model records the pass.
    ///   - holding: The task of the holding answer.
    /// - Throws: The error of `#require` when the holding answer ended first,
    ///   or ``ConditionNeverHeld`` when the test was cancelled first.
    private static func waitForTheHoldingPass(
        of fixture: PassObservingFixture, endingOnEndOf holding: Task<String, any Error>
    ) async throws {
        try await RecordedWaitResult.wait(for: { try await fixture.passes.waitForPasses(1) }, endingOnEndOf: holding)
    }

    /// The dimensions of a metric of one session: its model and its slot.
    ///
    /// - Parameter session: The session.
    /// - Returns: The `model.ref` and `slot` dimensions.
    private static func sessionDimensions(of session: any RoutedSession) -> [(String, String)] {
        [("model.ref", session.modelRefDimension), ("slot", ModelSlot.standard.rawValue)]
    }

    /// Makes `count` sessions on the standard slot of a profile over a new
    /// ``PassObservingFixture``, runs `body` with them, and then ends them.
    ///
    /// The latch of the fixture holds each pass until `body` opens it. The
    /// end opens the latch, closes each session and removes the temp
    /// directory, also when `body` throws (rule T1). The end runs after
    /// `body` returns the metrics that it read, so a record of a close
    /// changes no value that a test checks.
    ///
    /// - Parameters:
    ///   - count: How many sessions to make.
    ///   - isolation: The isolation of the caller. `body` runs there.
    ///   - body: The steps of the test, given the fixture, the profile and
    ///     the sessions in the order that they were made.
    /// - Returns: What `body` returns.
    /// - Throws: What the resolve or `body` throws.
    private static func withHeldSessions<Value>(
        count: Int,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (PassObservingFixture, LanguageModelProfile, [any RoutedSession]) async throws -> Value
    ) async throws -> Value {
        let dir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let sessions = (0..<count).map { _ in resolved.profile.standard.makeSession() }
        defer {
            for session in sessions {
                await SessionFixtureLifecycle.close(session, opening: [fixture.latch])
            }
            withExtendedLifetime(resolved) {}
        }
        return try await body(fixture, resolved.profile, sessions)
    }

    // MARK: - The vocabulary

    @Test("each metric name starts with the module name")
    func metricNamesStartWithTheModuleName() {
        for name in RouterTelemetry.MetricName.allNames {
            #expect(name.hasPrefix("FoundationModelsRouter."), "\(name) has no module prefix")
        }
    }

    // MARK: - Generation calls

    @Test("each generation call adds its tokens in, cached and out, and each submission records its time to first token")
    func generationCallsRecordTokensAndTimes() async throws {
        let metrics = try await TelemetryCapture.run(forbidding: [Self.meteredPrompt]) { context in
            let fixture = try await MeteredToolLoopSessionFixture.make(
                calls: Self.meteredCalls, context: Self.meteredContextTokens, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            await fixture.session.useCaptureMetrics(for: context.metricsFactory)

            for try await _ in await fixture.session.streamEvents(to: Self.meteredPrompt, maxTokens: nil) {}
            return (context.metricsFactory, Self.sessionDimensions(of: fixture.session))
        }

        let (factory, dimensions) = metrics
        let tokensIn = try factory.expectCounter("FoundationModelsRouter.generation.tokens.in", dimensions)
        let tokensOut = try factory.expectCounter("FoundationModelsRouter.generation.tokens.out", dimensions)
        #expect(tokensIn.totalValue == Self.meteredTokensIn)
        #expect(tokensOut.totalValue == Self.meteredTokensOut)
        let tokensCached = try factory.expectCounter("FoundationModelsRouter.generation.tokens.cached", dimensions)
        #expect(tokensCached.totalValue == Self.meteredTokensCached)
        let firstToken = try factory.expectTimer("FoundationModelsRouter.generation.time_to_first_token", dimensions)
        #expect(!firstToken.values.isEmpty)
        #expect(firstToken.values.allSatisfy { $0 >= 0 })
    }

    /// The scripted calls of the paced answer: the calls of the metered
    /// answer, each with a prefill and a decode, so the session sees the first
    /// token of each call.
    private static let pacedCalls = meteredCalls.map { call in
        MeteredGenerationCall(
            tokensIn: call.tokensIn, tokensOut: call.tokensOut, tokensCached: call.tokensCached,
            pacing: MeteredCallPacing(prefill: .milliseconds(20), decode: .milliseconds(20)))
    }

    @Test("each generation call records its time to first token and its decode time")
    func generationCallsRecordPrefillAndDecodeTimes() async throws {
        let metrics = try await TelemetryCapture.run(forbidding: [Self.meteredPrompt]) { context in
            let fixture = try await MeteredToolLoopSessionFixture.make(
                calls: Self.pacedCalls, context: Self.meteredContextTokens, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            await fixture.session.useCaptureMetrics(for: context.metricsFactory)

            for try await _ in await fixture.session.streamEvents(to: Self.meteredPrompt, maxTokens: nil) {}
            return (context.metricsFactory, Self.sessionDimensions(of: fixture.session))
        }

        let (factory, dimensions) = metrics
        let firstToken = try factory.expectTimer(
            "FoundationModelsRouter.generation.call.time_to_first_token", dimensions)
        let decode = try factory.expectTimer("FoundationModelsRouter.generation.call.decode_time", dimensions)
        #expect(firstToken.values.count == Self.pacedCalls.count)
        #expect(decode.values.count == Self.pacedCalls.count)
        #expect(firstToken.values.allSatisfy { $0 >= 0 })
        #expect(decode.values.allSatisfy { $0 >= 0 })
    }

    @Test("the tokens per second of each generation call are its generated tokens over its decode time")
    func tokensPerSecondDividesByTheDecodeTime() async throws {
        let (factory, dimensions, calls) = try await TelemetryCapture.run(forbidding: [Self.meteredPrompt]) {
            context in
            let fixture = try await MeteredToolLoopSessionFixture.make(
                calls: Self.pacedCalls, context: Self.meteredContextTokens, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            await fixture.session.useCaptureMetrics(for: context.metricsFactory)

            let events = try await collect(fixture.session.streamEvents(to: Self.meteredPrompt, maxTokens: nil))
            return (context.metricsFactory, Self.sessionDimensions(of: fixture.session), events.generationCalls)
        }

        let tokensPerSecond = try factory.expectRecorder(
            "FoundationModelsRouter.generation.tokens_per_second", dimensions)
        let expected = try calls.map { call in
            Double(call.tokensOut) / (try #require(call.decodeTime)).seconds
        }
        #expect(calls.count == Self.pacedCalls.count)
        #expect(tokensPerSecond.values == expected)
    }

    // MARK: - Compactions

    @Test("a caller compaction adds one to the compaction count of the caller trigger")
    func callerCompactionIsCounted() async throws {
        let factory = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: nil, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            let session = fixture.session
            await session.useCaptureMetrics(for: context.metricsFactory)

            _ = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)
            return context.metricsFactory
        }

        let count = try factory.expectCounter(
            "FoundationModelsRouter.compaction.count", [("compaction.trigger", "caller")])
        #expect(count.totalValue == 1)
        #expect(throws: TestMetricsError.self) {
            try factory.expectCounter("FoundationModelsRouter.compaction.count", [("compaction.trigger", "auto")])
        }
    }

    @Test("an automatic compaction adds one to the compaction count of the auto trigger")
    @MainActor
    func automaticCompactionIsCounted() async throws {
        let factory = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: AutoCompactionFixtures.fixedBudget, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            let session = fixture.session
            await session.useCaptureMetrics(for: context.metricsFactory)

            for try await _ in await session.streamEvents(to: Self.triggeringPrompt, maxTokens: nil) {}
            return context.metricsFactory
        }

        let count = try factory.expectCounter(
            "FoundationModelsRouter.compaction.count", [("compaction.trigger", "auto")])
        #expect(count.totalValue == 1)
    }

    // MARK: - Loads and resident memory

    @Test("a resolve records the load duration of each model it loads, by model and slot")
    func resolveRecordsEachLoadDuration() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }

        let (factory, profile) = try await TelemetryCapture.run(forbidding: []) { context in
            let router = RouterTestFixtures.makeRouter(
                cacheDir: dir,
                loader: StubModelLoader(
                    container: UndrivenLanguageModelContainer(), dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return (context.metricsFactory, profile)
        }

        let slots: [(slot: ModelSlot, chosen: ModelRef)] = [
            (.standard, profile.standard.chosen), (.flash, profile.flash.chosen), (.embedding, profile.embedding.chosen),
        ]
        for slot in slots {
            let timer = try factory.expectTimer(
                "FoundationModelsRouter.load.duration",
                [("model.ref", slot.chosen.stringValue), ("slot", slot.slot.rawValue)])
            #expect(timer.values.count == 1)
            #expect(timer.values.allSatisfy { $0 >= 0 })
        }
    }

    @Test("a resolve that changes the footprint of the pool sets the resident bytes gauge to the new footprint")
    func resolveSetsTheResidentBytesGauge() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }

        try await TelemetryCapture.run(forbidding: []) { context in
            let factory = context.metricsFactory
            let signalling = SignallingMetricsFactory(wrapping: factory)
            // The footprints task of the router is a plain task. It reads the
            // factory that is bound when the router is made, so each gauge
            // record of that task signals `signalling.changes`.
            try await withMetricsFactory(signalling) {
                let router = RouterTestFixtures.makeRouter(
                    cacheDir: dir,
                    loader: StubModelLoader(
                        container: UndrivenLanguageModelContainer(), dimension: RouterTestFixtures.stubDimension))
                let profile = try await router.resolve(
                    profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
                let residentBytes = Double(router.pool.footprint.totalBytes)
                #expect(residentBytes > 0)

                try await signalling.changes.wait(until: {
                    (try? factory.expectGauge(Self.residentBytesName))?.lastValue == residentBytes
                })
                withExtendedLifetime(profile) {}
            }
        }
    }

    // MARK: - Queues

    @Test(
        "a caller message that waits behind the running answer is recorded in the queue depth of the session, by mail kind"
    )
    func waitingMessagesAreRecordedInTheSessionQueueDepth() async throws {
        let depths = try await Self.withHeldSessions(count: 1) { fixture, _, sessions in
            let session = try #require(sessions.first)
            return try await TelemetryCapture.run(forbidding: [Self.holdingPrompt] + Self.waitingPrompts) {
                context in
                await session.useCaptureMetrics(for: context.metricsFactory)
                let holding = Task { try await session.respond(to: Self.holdingPrompt) }
                try await Self.waitForTheHoldingPass(of: fixture, endingOnEndOf: holding)
                for prompt in Self.waitingPrompts {
                    _ = try session.send(prompt)
                }
                await fixture.latch.open()
                _ = try await holding.value
                // The session is idle only after its pump answered the waiting
                // messages, so the queue is empty when the test reads it.
                #expect(await session.becomesIdle())
                #expect(await session.mailQueueDepth().total == 0)
                return try MailKind.allCases.map { kind in
                    (
                        kind,
                        try context.metricsFactory.expectRecorder(Self.queueDepthName, [("mail.kind", kind.rawValue)])
                            .values
                    )
                }
            }
        }

        // Each record gives the count of each kind, so each kind has values,
        // and only the user messages waited.
        let userDepths = try #require(depths.first { $0.0 == .userMessage }?.1)
        #expect(userDepths.contains(Double(Self.waitingPrompts.count)))
        for (kind, values) in depths {
            #expect(!values.isEmpty, "no queue depth of \(kind.rawValue)")
            #expect(values.allSatisfy { $0 >= 0 })
            if kind != .userMessage {
                #expect(values.allSatisfy { $0 == 0 }, "the queue depths of \(kind.rawValue) are \(values)")
            }
        }
    }

    @Test("a cancel of a waiting message adds one to the count of cancelled mail")
    func cancelledMailIsCounted() async throws {
        let count = try await Self.withHeldSessions(count: 1) { fixture, _, sessions in
            let session = try #require(sessions.first)
            return try await TelemetryCapture.run(forbidding: [Self.holdingPrompt] + Self.waitingPrompts) {
                context in
                await session.useCaptureMetrics(for: context.metricsFactory)
                let holding = Task { try await session.respond(to: Self.holdingPrompt) }
                try await Self.waitForTheHoldingPass(of: fixture, endingOnEndOf: holding)
                let waiting = try session.send(Self.waitingPrompts[0])
                let cancel = session.cancel(waiting)
                #expect(try await session.awaitTerminal(of: cancel) == .signalDone(cancel))
                #expect(try await session.awaitTerminal(of: waiting) == .cancelled(waiting))
                await fixture.latch.open()
                _ = try await holding.value
                return try context.metricsFactory.expectCounter(Self.cancelledMailName).totalValue
            }
        }

        #expect(count == 1)
    }

    @Test("a compaction records the time that it paused the mail queue")
    func compactionRecordsThePauseOfTheMailQueue() async throws {
        let values = try await TelemetryCapture.run(forbidding: []) { context in
            let fixture = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: nil, tempDirPrefix: Self.tempDirPrefix)
            defer { await fixture.end() }
            let session = fixture.session
            let factory = context.metricsFactory
            let signalling = SignallingMetricsFactory(wrapping: factory)
            await session.useCaptureMetrics(for: signalling)

            _ = try await session.compactAndAwait(budget: AutoCompactionFixtures.fixedBudget)
            // The queue resumes after the terminal event of the compaction.
            // The record of the pause at the resume signals
            // `signalling.changes`.
            try await signalling.changes.wait(until: {
                (try? factory.expectTimer(Self.pauseDurationName))?.values.isEmpty == false
            })
            return try factory.expectTimer(Self.pauseDurationName).values
        }

        #expect(values.count == 1)
        #expect(values.allSatisfy { $0 >= 0 })
    }

    @Test("a submission that starts while others wait records the waiting count of the queue of its model")
    func waitingSubmissionsAreRecordedInTheGenerationQueueGauge() async throws {
        let (values, modelRef) = try await Self.withHeldSessions(count: 1 + Self.waitingPrompts.count) {
            fixture, profile, sessions in
            let queue = try #require(profile.standard.backendQueue)
            let holding = try #require(sessions.first)
            let waiting = Array(sessions.dropFirst())
            return try await TelemetryCapture.run(forbidding: [Self.holdingPrompt] + Self.waitingPrompts) {
                context in
                for session in sessions {
                    await session.useCaptureMetrics(for: context.metricsFactory)
                }
                var feeds: [(log: SessionEventLog, drain: Task<Void, Never>)] = []
                for session in waiting {
                    feeds.append(await SessionEventLog.watch(session))
                }
                let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
                try await Self.waitForTheHoldingPass(of: fixture, endingOnEndOf: holdingAnswer)
                var waitingAnswers: [Task<String, any Error>] = []
                for (index, session) in waiting.enumerated() {
                    let prompt = Self.waitingPrompts[index]
                    let answer = Task { try await session.respond(to: prompt) }
                    waitingAnswers.append(answer)
                    // The queue counts the submission before it reports the wait,
                    // and the holding answer keeps each submission in the queue.
                    // The wait also ends when the answer ended (rule T1): the
                    // latch holds the answer in the queue, so in a test that
                    // passes it cannot end first.
                    let log = feeds[index].log
                    try await RecordedWaitResult.wait(
                        for: { try await log.wait(until: { Self.containsQueuedSubmission($0) }) },
                        endingOnEndOf: answer)
                    #expect(await queue.waitingCount == index + 1)
                }
                await fixture.latch.open()
                _ = try await holdingAnswer.value
                for answer in waitingAnswers {
                    _ = try await answer.value
                }
                for feed in feeds {
                    feed.drain.cancel()
                }
                let gauge = try context.metricsFactory.expectGauge(
                    "FoundationModelsRouter.generation_queue.waiting", [("model.ref", holding.modelRefDimension)])
                return (gauge.values, holding.modelRefDimension)
            }
        }

        // The second submission starts when the first one ends, while the
        // third one still waits behind it.
        #expect(values.contains(1), "the waiting counts of \(modelRef) are \(values)")
        #expect(values.allSatisfy { $0 >= 0 })
    }

    // MARK: - The explicit factory of a session

    @Test("a fork starts with the explicit metrics factory of its parent")
    func forkKeepsTheExplicitMetricsFactory() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(
                container: CannedLLMContainer(ref: "org/std-a"), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        defer { await session.close() }

        let factory = try await TelemetryCapture.run(forbidding: []) { context in
            await session.useCaptureMetrics(for: context.metricsFactory)
            let fork = try await session.fork(workingDirectory: nil)
            defer { await fork.close() }
            let child = try #require(fork as? RoutedSessionActor)
            // A detached task gets no capture of its own, so only the explicit
            // factory of the child can bring this metric to the capture.
            await Task.detached {
                child.sessionMetrics.recordCompaction(trigger: .caller)
            }.value
            return context.metricsFactory
        }

        let count = try factory.expectCounter(
            "FoundationModelsRouter.compaction.count", [("compaction.trigger", "caller")])
        #expect(count.totalValue == 1)
    }
}

/// A metrics factory that makes each metric through the `TestMetrics` of a
/// capture, and signals ``changes`` after each value of a recorder (also a
/// gauge) or of a timer.
///
/// `TestMetrics` sends no event when a metric gets a value. A test gives this
/// factory to the code under test, and waits on ``changes`` for the value
/// that it reads back from the `TestMetrics`. Each metric stays in the
/// `TestMetrics`, so the capture still checks its name and its dimensions.
/// A counter and a meter get no signal: no test waits for one.
final class SignallingMetricsFactory: MetricsFactory {
    /// The factory that makes and keeps each metric.
    let inner: TestMetrics

    /// The signal that each value of a recorder or a timer sends.
    let changes = ChangeSignal()

    /// Makes a factory over `inner`.
    ///
    /// - Parameter inner: The factory that makes and keeps each metric.
    init(wrapping inner: TestMetrics) {
        self.inner = inner
    }

    /// Makes the counter in ``inner``. It sends no signal.
    ///
    /// - Parameters:
    ///   - label: The label of the counter.
    ///   - dimensions: The dimensions of the counter.
    /// - Returns: The counter of ``inner``.
    func makeCounter(label: String, dimensions: [(String, String)]) -> CounterHandler {
        inner.makeCounter(label: label, dimensions: dimensions)
    }

    /// Makes the recorder in ``inner``, wrapped so that each value signals
    /// ``changes``.
    ///
    /// - Parameters:
    ///   - label: The label of the recorder.
    ///   - dimensions: The dimensions of the recorder.
    ///   - aggregate: Whether the recorder aggregates its values.
    /// - Returns: The wrapped recorder.
    func makeRecorder(label: String, dimensions: [(String, String)], aggregate: Bool) -> RecorderHandler {
        SignallingRecorder(
            inner: inner.makeRecorder(label: label, dimensions: dimensions, aggregate: aggregate), changes: changes)
    }

    /// Makes the timer in ``inner``, wrapped so that each value signals
    /// ``changes``.
    ///
    /// - Parameters:
    ///   - label: The label of the timer.
    ///   - dimensions: The dimensions of the timer.
    /// - Returns: The wrapped timer.
    func makeTimer(label: String, dimensions: [(String, String)]) -> TimerHandler {
        SignallingTimer(inner: inner.makeTimer(label: label, dimensions: dimensions), changes: changes)
    }

    /// Destroys the counter in ``inner``.
    ///
    /// - Parameter handler: The counter to destroy.
    func destroyCounter(_ handler: CounterHandler) {
        inner.destroyCounter(handler)
    }

    /// Destroys the recorder in ``inner``.
    ///
    /// - Parameter handler: The recorder to destroy, wrapped or not.
    func destroyRecorder(_ handler: RecorderHandler) {
        inner.destroyRecorder((handler as? SignallingRecorder)?.inner ?? handler)
    }

    /// Destroys the timer in ``inner``.
    ///
    /// - Parameter handler: The timer to destroy, wrapped or not.
    func destroyTimer(_ handler: TimerHandler) {
        inner.destroyTimer((handler as? SignallingTimer)?.inner ?? handler)
    }
}

/// A recorder that gives each value to a recorder of a `TestMetrics`, and
/// then signals a change.
private final class SignallingRecorder: RecorderHandler {
    /// The recorder that keeps the values.
    let inner: any RecorderHandler

    /// The signal that each value sends.
    let changes: ChangeSignal

    /// Makes a recorder over `inner`.
    ///
    /// - Parameters:
    ///   - inner: The recorder that keeps the values.
    ///   - changes: The signal that each value sends.
    init(inner: any RecorderHandler, changes: ChangeSignal) {
        self.inner = inner
        self.changes = changes
    }

    /// Records `value` in ``inner``, then signals ``changes``.
    ///
    /// - Parameter value: The value.
    func record(_ value: Int64) {
        inner.record(value)
        changes.signal()
    }

    /// Records `value` in ``inner``, then signals ``changes``.
    ///
    /// - Parameter value: The value.
    func record(_ value: Double) {
        inner.record(value)
        changes.signal()
    }
}

/// A timer that gives each duration to a timer of a `TestMetrics`, and then
/// signals a change.
private final class SignallingTimer: TimerHandler {
    /// The timer that keeps the durations.
    let inner: any TimerHandler

    /// The signal that each duration sends.
    let changes: ChangeSignal

    /// Makes a timer over `inner`.
    ///
    /// - Parameters:
    ///   - inner: The timer that keeps the durations.
    ///   - changes: The signal that each duration sends.
    init(inner: any TimerHandler, changes: ChangeSignal) {
        self.inner = inner
        self.changes = changes
    }

    /// Records `duration` in ``inner``, then signals ``changes``.
    ///
    /// - Parameter duration: The duration in nanoseconds.
    func recordNanoseconds(_ duration: Int64) {
        inner.recordNanoseconds(duration)
        changes.signal()
    }

    /// Gives the display unit to ``inner``.
    ///
    /// - Parameter unit: The unit to display the durations in.
    func preferDisplayUnit(_ unit: TimeUnit) {
        inner.preferDisplayUnit(unit)
    }
}
