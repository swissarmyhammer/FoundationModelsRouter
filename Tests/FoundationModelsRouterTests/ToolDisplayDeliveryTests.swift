import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises task ^twha0gz: a display event that a tool posts through
/// `ToolContext.emit(chunk:)` goes live to the host as
/// ``SessionEvent/toolDisplay(_:)``.
///
/// - The event arrives on the stream of the answer and on the session feed,
///   in post order with the progress events of the same run.
/// - The event never goes into the input of a later submission.
/// - A run that settles inside its settle period keeps its display events.
/// - A display event resets the timeout of the run, the same as progress.
///
/// A ``BackgroundingBackend`` calls the background tool of the session in its
/// first answer. No assertion reads a clock: each wait reads a state until it
/// holds, and the `.timeLimit` of the suite ends a wait for a state that never
/// comes. Only the timeout test sleeps, because the timeout of a run is a
/// time.
@Suite("The live delivery of the display events of a tool", .timeLimit(.minutes(1)))
struct ToolDisplayDeliveryTests {
    // MARK: - Fixtures

    /// Thrown by ``DisplayingBackgroundTool`` when no ambient ``ToolContext``
    /// is bound around its call.
    struct ToolContextMissing: Error {}

    /// A background tool that posts its ``steps`` through the ambient
    /// ``ToolContext``, in order, then waits for its gate and returns
    /// ``ToolDisplayDeliveryTests/runOutput``.
    struct DisplayingBackgroundTool: Tool, BackgroundTool {
        /// One post of the body of the tool.
        enum Step: Sendable, Equatable {
            /// A progress event with this detail, through
            /// `ToolContext.progress(_:plan:)`.
            case progress(String)

            /// A display event that adds this text to the output of the
            /// call, through `ToolContext.emit(chunk:)`.
            case display(String)
        }

        let name = "displaying_job"
        let description = "test-only background tool that posts progress and display events"

        /// The posts of the body, in order.
        let steps: [Step]

        /// The pause before each post.
        var pause: Duration = .zero

        /// The timeout of the run with no sign of life, or `nil` for none.
        var timeout: TimeInterval?

        /// The latch the body waits on after its posts, or `nil` to return at
        /// once.
        var gate: RunLatch?

        var mount: ToolMount? {
            ToolMount(mode: .background, timeout: timeout)
        }

        func call(arguments: BackgroundFixtureArguments) async throws -> String {
            guard let context = ToolContext.current else { throw ToolContextMissing() }
            for step in steps {
                try await Task.sleep(for: pause)
                await Self.post(step, through: context)
            }
            await gate?.waitUntilOpen()
            return ToolDisplayDeliveryTests.runOutput
        }

        /// Posts `step` through `context`.
        ///
        /// - Parameters:
        ///   - step: The post.
        ///   - context: The context of the call.
        private static func post(_ step: Step, through context: ToolContext) async {
            switch step {
            case .progress(let detail):
                await context.progress(detail)
            case .display(let text):
                await context.emit(chunk: .text(text))
            }
        }
    }

    /// One session over a ``BackgroundingBackend``, with what a test reads.
    struct Fixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend the session runs on.
        let backend: BackgroundingBackend

        /// The feed of the session's events.
        let events: SessionEventLog

        /// The task that drains ``events``.
        let drain: Task<Void, Never>

        /// The router that keeps the models of the session resident.
        let router: Router

        /// The temporary directory the router caches under.
        let directory: URL
    }

    // MARK: - Constants

    /// The output of the run of ``DisplayingBackgroundTool``.
    static let runOutput = "the job is done"

    /// The prompt of the caller message that starts the run.
    private static let jobPrompt = "run the job"

    /// The prompt of the caller message after the run started.
    private static let nextPrompt = "how is the job"

    /// The number of display events of the timeout test.
    private static let beatCount = 8

    /// The pause between two display events of the timeout test, well inside
    /// ``beatTimeout``.
    private static let beatPause: Duration = .milliseconds(100)

    /// The timeout that the display events of the timeout test start again.
    /// The full run is longer.
    private static let beatTimeout: TimeInterval = 0.5

    // MARK: - Helpers

    /// Makes a session with `tool` and the settle period `grace`, and watches
    /// the events of the session.
    ///
    /// - Parameters:
    ///   - tool: The background tool of the session.
    ///   - grace: The ``SessionConfiguration/inlineSettleGrace`` of the
    ///     session.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profile throws.
    @MainActor
    private static func makeFixture(tool: DisplayingBackgroundTool, grace: TimeInterval) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: "ToolDisplayDeliveryTests")
        let container = BackgroundingLLMContainer()
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [tool], inlineSettleGrace: grace))
        let backend = try #require(container.lastBackend)
        let (events, drain) = await SessionEventLog.watch(session)
        return Fixture(
            session: session, backend: backend, events: events, drain: drain, router: router,
            directory: directory)
    }

    /// Ends the fixture: stops the event drain, closes the session and
    /// removes the directory.
    ///
    /// - Parameter fixture: The fixture to end.
    private static func end(_ fixture: Fixture) async {
        fixture.drain.cancel()
        await fixture.session.close()
        try? FileManager.default.removeItem(at: fixture.directory)
        withExtendedLifetime(fixture.router) {}
    }

    /// Every event of the answer to `prompt` on `session`, in delivery order.
    ///
    /// - Parameters:
    ///   - prompt: The prompt of the answer.
    ///   - session: The session that answers.
    /// - Returns: The events of the answer.
    /// - Throws: What the stream of the answer throws.
    private static func streamedEvents(answering prompt: String, on session: any RoutedSession) async throws
        -> [SessionEvent]
    {
        var events: [SessionEvent] = []
        for try await event in await session.streamEvents(to: prompt) {
            events.append(event)
        }
        return events
    }

    // MARK: - The stream of the answer

    @Test("each display event of a tool arrives on streamEvents(to:) as toolDisplay, in post order with its progress events")
    @MainActor
    func displayEventsArriveInOrderWithProgress() async throws {
        let steps: [DisplayingBackgroundTool.Step] = [
            .progress("reading the files"), .display("first output line"),
            .progress("writing the files"), .display("second output line"),
        ]
        let fixture = try await Self.makeFixture(
            tool: DisplayingBackgroundTool(steps: steps), grace: MountFixtures.generousInterval)

        let events = try await Self.streamedEvents(answering: Self.jobPrompt, on: fixture.session)

        // The background runner also posts a progress event of its own, with
        // the pending envelope of the run. Only the posts of the tool count.
        #expect(events.compactMap(\.displayingToolStep).filter(steps.contains) == steps)
        await Self.end(fixture)
    }

    // MARK: - The input of the model

    @Test("the input of the next submission holds the progress of the run and not its display event")
    @MainActor
    func theNextInputHoldsNoDisplayEvent() async throws {
        let progress = "reading the files"
        let display = "first output line"
        let gate = RunLatch()
        // The settle period is zero, so the call answers with a pending
        // envelope, and the run stays open on its gate.
        let fixture = try await Self.makeFixture(
            tool: DisplayingBackgroundTool(steps: [.progress(progress), .display(display)], gate: gate), grace: 0)
        _ = try await fixture.session.respond(to: Self.jobPrompt)
        try #require(
            await BoundedWait.conditionReached("the display event on the session feed") {
                await fixture.events.displayTexts == [display]
            })

        _ = try await fixture.session.respond(to: Self.nextPrompt)

        let input = try #require(fixture.backend.receivedPrompts.last)
        #expect(input.contains(progress))
        #expect(input.contains(display) == false)
        await gate.open()
        await Self.end(fixture)
    }

    // MARK: - The settle period

    @Test("a display event of a run that settles inside its settle period arrives on streamSessionEvents()")
    @MainActor
    func aRunThatSettlesInsideTheGraceKeepsItsDisplayEvents() async throws {
        let display = "output inside the settle period"
        let fixture = try await Self.makeFixture(
            tool: DisplayingBackgroundTool(steps: [.display(display)]), grace: MountFixtures.generousInterval)

        let answer = try await fixture.session.respond(to: Self.jobPrompt)

        // The run settled inside the settle period: the call answers with the
        // own output of the tool, and the staged events of the run are
        // withdrawn. The display event stays with the host.
        #expect(answer == Self.runOutput)
        #expect(await fixture.session.outbox.pending().events.isEmpty)
        #expect(
            await BoundedWait.conditionReached("the display event on the session feed") {
                await fixture.events.displayTexts == [display]
            })
        await Self.end(fixture)
    }

    // MARK: - The timeout of the run

    @Test("a tool that sends display events faster than its timeout runs past the timeout, and each event arrives")
    @MainActor
    func displayEventsResetTheTimeout() async throws {
        let texts = (0..<Self.beatCount).map { "beat \($0)" }
        let tool = DisplayingBackgroundTool(
            steps: texts.map(DisplayingBackgroundTool.Step.display), pause: Self.beatPause,
            timeout: Self.beatTimeout)
        let fixture = try await Self.makeFixture(tool: tool, grace: MountFixtures.generousInterval)

        let answer = try await fixture.session.respond(to: Self.jobPrompt)

        #expect(answer == Self.runOutput)
        #expect(
            await BoundedWait.conditionReached("each display event on the session feed") {
                await fixture.events.displayTexts == texts
            })
        await Self.end(fixture)
    }
}

extension SessionEvent {
    /// The post of a ``ToolDisplayDeliveryTests/DisplayingBackgroundTool``
    /// that this event carries: a progress event, or a display event that
    /// adds a text. `nil` for each other event.
    var displayingToolStep: ToolDisplayDeliveryTests.DisplayingBackgroundTool.Step? {
        if case .runProgress(let progress) = self {
            return .progress(progress.detail)
        }
        if case .toolDisplay(let display) = self, case .contentChunk(.text(let text)) = display.kind {
            return .display(text)
        }
        return nil
    }
}

extension SessionEventLog {
    /// The text of each display event delivered so far that adds a text, in
    /// delivery order.
    var displayTexts: [String] {
        events.compactMap { event in
            guard case .display(let text) = event.displayingToolStep else { return nil }
            return text
        }
    }
}
