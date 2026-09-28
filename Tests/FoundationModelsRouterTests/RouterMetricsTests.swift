import Foundation
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
/// to be recorded and not negative: no test waits on the clock.
@Suite("The router records its metrics through swift-metrics with the names of its vocabulary")
struct RouterMetricsTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "RouterMetricsTests"

    /// The prompt of the metered tool-loop answer. No metric may carry it.
    private static let meteredPrompt = "look things up, then tell me what you found"

    /// The scripted usage of the three generation calls of the metered answer.
    private static let meteredCalls = [
        MeteredGenerationCall(tokensIn: 100, tokensOut: 30),
        MeteredGenerationCall(tokensIn: 200, tokensOut: 50),
        MeteredGenerationCall(tokensIn: 300, tokensOut: 70),
    ]

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

    /// The dimensions of a metric of one session: its model and its slot.
    ///
    /// - Parameter session: The session.
    /// - Returns: The `model.ref` and `slot` dimensions.
    private static func sessionDimensions(of session: RoutedSession) -> [(String, String)] {
        [("model.ref", session.modelRefDimension), ("slot", ModelSlot.standard.rawValue)]
    }

    // MARK: - The vocabulary

    @Test("each metric name starts with the module name")
    func metricNamesStartWithTheModuleName() {
        for name in RouterTelemetry.MetricName.allNames {
            #expect(name.hasPrefix("FoundationModelsRouter."), "\(name) has no module prefix")
        }
    }

    // MARK: - Generation calls

    @Test("each generation call adds its tokens in and out, and records its tokens per second and the time to first token")
    func generationCallsRecordTokensAndTimes() async throws {
        let metrics = try await TelemetryCapture.run(forbidding: [Self.meteredPrompt]) { context in
            let fixture = try await MeteredToolLoopSessionFixture.make(
                calls: Self.meteredCalls, context: Self.meteredContextTokens, tempDirPrefix: Self.tempDirPrefix)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            await fixture.session.useCaptureMetrics(for: context.metricsFactory)

            for try await _ in await fixture.session.streamEvents(to: Self.meteredPrompt, maxTokens: nil) {}
            return (context.metricsFactory, Self.sessionDimensions(of: fixture.session))
        }

        let (factory, dimensions) = metrics
        let tokensIn = try factory.expectCounter("FoundationModelsRouter.generation.tokens.in", dimensions)
        let tokensOut = try factory.expectCounter("FoundationModelsRouter.generation.tokens.out", dimensions)
        #expect(tokensIn.totalValue == Self.meteredTokensIn)
        #expect(tokensOut.totalValue == Self.meteredTokensOut)
        let tokensPerSecond = try factory.expectRecorder(
            "FoundationModelsRouter.generation.tokens_per_second", dimensions)
        #expect(tokensPerSecond.values.count == Self.meteredCalls.count)
        #expect(tokensPerSecond.values.allSatisfy { $0 >= 0 })
        let firstToken = try factory.expectTimer("FoundationModelsRouter.generation.time_to_first_token", dimensions)
        #expect(!firstToken.values.isEmpty)
        #expect(firstToken.values.allSatisfy { $0 >= 0 })
    }

    // MARK: - Compactions

    @Test("a caller compaction adds one to the compaction count of the caller trigger")
    func callerCompactionIsCounted() async throws {
        let factory = try await TelemetryCapture.run(forbidding: []) { context in
            let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: nil, tempDirPrefix: Self.tempDirPrefix)
            await session.useCaptureMetrics(for: context.metricsFactory)

            _ = try await session.compact(budget: AutoCompactionFixtures.fixedBudget)
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
            let (session, _, _) = try await AutoCompactionFixtures.makeTriggeredSession(
                budget: AutoCompactionFixtures.fixedBudget, tempDirPrefix: Self.tempDirPrefix)
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
            let router = RouterTestFixtures.makeRouter(
                cacheDir: dir,
                loader: StubModelLoader(
                    container: UndrivenLanguageModelContainer(), dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let residentBytes = Double(router.pool.footprint.totalBytes)
            #expect(residentBytes > 0)

            let factory = context.metricsFactory
            let reached = await BoundedWait.conditionReached("the resident bytes of the resolved profile") {
                (try? factory.expectGauge("FoundationModelsRouter.model_pool.resident_bytes"))?.lastValue
                    == residentBytes
            }
            #expect(reached)
            withExtendedLifetime(profile) {}
        }
    }

    // MARK: - Queues

    @Test("a caller message that waits behind the running answer is recorded in the queue depth of the session")
    func waitingMessagesAreRecordedInTheSessionQueueDepth() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let session = resolved.profile.standard.makeSession()

        let depths = try await TelemetryCapture.run(forbidding: [Self.holdingPrompt] + Self.waitingPrompts) {
            context in
            await session.useCaptureMetrics(for: context.metricsFactory)
            let holding = Task { try await session.respond(to: Self.holdingPrompt) }
            let holdingInside = await BoundedWait.conditionReached("the pass of the holding answer") {
                fixture.passes.recorded.count == 1
            }
            for prompt in Self.waitingPrompts {
                _ = await session.send(prompt)
            }
            await fixture.latch.open()
            _ = try await holding.value
            let drained = await BoundedWait.conditionReached("the answer of the waiting messages") {
                await session.messageQueueDepth().total == 0
            }
            #expect(holdingInside)
            #expect(drained)
            return try context.metricsFactory.expectRecorder("FoundationModelsRouter.session.queue_depth").values
        }

        #expect(depths.contains(Double(Self.waitingPrompts.count)))
        #expect(depths.allSatisfy { $0 >= 0 })
        withExtendedLifetime(resolved) {}
    }

    @Test("a submission that starts while others wait records the waiting count of the queue of its model")
    func waitingSubmissionsAreRecordedInTheGenerationQueueGauge() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = PassObservingFixture()
        let resolved = try await RouterTestFixtures.resolveStandardProfile(over: fixture.container, cacheDir: dir)
        let queue = try #require(resolved.profile.standard.backendQueue)
        let holding = resolved.profile.standard.makeSession()
        let waiting = Self.waitingPrompts.map { _ in resolved.profile.standard.makeSession() }

        let (values, modelRef) = try await TelemetryCapture.run(
            forbidding: [Self.holdingPrompt] + Self.waitingPrompts
        ) { context in
            for session in [holding] + waiting {
                await session.useCaptureMetrics(for: context.metricsFactory)
            }
            let holdingAnswer = Task { try await holding.respond(to: Self.holdingPrompt) }
            let holdingInside = await BoundedWait.conditionReached("the pass of the holding answer") {
                fixture.passes.recorded.count == 1
            }
            var waitingAnswers: [Task<String, any Error>] = []
            for (index, session) in waiting.enumerated() {
                let prompt = Self.waitingPrompts[index]
                waitingAnswers.append(Task { try await session.respond(to: prompt) })
                let queued = await BoundedWait.conditionReached("waiting submission \(index + 1)") {
                    await queue.waitingCount == index + 1
                }
                #expect(queued)
            }
            await fixture.latch.open()
            _ = try await holdingAnswer.value
            for answer in waitingAnswers {
                _ = try await answer.value
            }
            #expect(holdingInside)
            let gauge = try context.metricsFactory.expectGauge(
                "FoundationModelsRouter.generation_queue.waiting", [("model.ref", holding.modelRefDimension)])
            return (gauge.values, holding.modelRefDimension)
        }

        // The second submission starts when the first one ends, while the
        // third one still waits behind it.
        #expect(values.contains(1), "the waiting counts of \(modelRef) are \(values)")
        #expect(values.allSatisfy { $0 >= 0 })
        withExtendedLifetime(resolved) {}
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

        let factory = try await TelemetryCapture.run(forbidding: []) { context in
            await session.useCaptureMetrics(for: context.metricsFactory)
            let child = try #require(try await session.fork(workingDirectory: nil) as? RoutedSessionActor)
            // A detached task gets no capture of its own, so only the explicit
            // factory of the child can bring this metric to the capture.
            await Task.detached {
                await child.sessionMetrics.recordCompaction(trigger: .caller)
            }.value
            return context.metricsFactory
        }

        let count = try factory.expectCounter(
            "FoundationModelsRouter.compaction.count", [("compaction.trigger", "caller")])
        #expect(count.totalValue == 1)
    }
}
