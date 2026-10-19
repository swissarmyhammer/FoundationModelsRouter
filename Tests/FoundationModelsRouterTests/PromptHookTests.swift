import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsHooks
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Holds the prompt hooks of a session (task ^qhwvd8s): each user message and
/// each agent message gets one `PrePrompt` before the model gets it, and one
/// `PostPrompt` when it ends.
///
/// The session screens a mail while the mail is in the queue. The pump takes
/// no mail from the first mail whose `PrePrompt` chain runs. A block withdraws
/// the mail, and a cancel of the mail while its chain runs withdraws it too.
///
/// Each test runs a session on ``MailQueueFixtures/Backend`` through a router
/// with a dispatcher, and registers a ``PromptRecordingVisitor`` on that
/// dispatcher. Each test closes the session and calls `dispatcher.drain()`
/// before it reads the post events, because a post event arrives on a task of
/// the dispatcher.
@Suite("Prompt hooks: PrePrompt and PostPrompt for each mail")
struct PromptHookTests {
    /// The backend the suite scripts.
    private typealias Backend = MailQueueFixtures.Backend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "PromptHookTests"

    /// The prompt of the message whose submission the test holds open.
    private static let heldPrompt = "held question"

    /// The prompt of the first message that a test sends.
    private static let firstPrompt = "first question"

    /// The prompt of the second message that a test sends.
    private static let secondPrompt = "second question"

    /// The text that a replacing visitor puts in place of the prompt.
    private static let replacedPrompt = "replaced question"

    /// The reason that a blocking visitor gives.
    private static let blockReason = "the prompt is not allowed"

    // MARK: - Fixtures

    /// A visitor that records each session event and each prompt event, in
    /// the order of delivery, and gives each `PrePrompt` the decision of the
    /// test.
    final class PromptRecordingVisitor: HookVisitor {
        /// One recorded event.
        enum Event: Equatable {
            /// A `SessionStart`.
            case start
            /// A `PrePrompt`, with the id of its mail and its text.
            case pre(mailID: String, text: String)
            /// A `PostPrompt`, with the id of its mail and its outcome.
            case post(mailID: String, outcome: PromptOutcome)
            /// A `SessionEnd`.
            case end
        }

        /// The recorded events.
        private let recorded = Mutex<[Event]>([])

        /// Signals after each recorded event.
        let changes = ChangeSignal()

        /// The decision that the visitor gives a `PrePrompt`.
        private let decide: @Sendable (PrePrompt) async -> PreDecision<PrePrompt>

        /// Makes a visitor.
        ///
        /// - Parameter decide: The decision for each `PrePrompt`. The default
        ///   lets each prompt go on as it is.
        init(decide: @escaping @Sendable (PrePrompt) async -> PreDecision<PrePrompt> = { _ in .proceed }) {
            self.decide = decide
        }

        /// The recorded events, in the order of delivery.
        var events: [Event] {
            recorded.withLock { $0 }
        }

        /// The ids of the mail of the recorded `PrePrompt` events, in order.
        var prePromptMailIDs: [String] {
            events.compactMap { event in
                guard case .pre(let mailID, _) = event else { return nil }
                return mailID
            }
        }

        /// The recorded `PostPrompt` events, in order.
        var postPrompts: [Event] {
            events.filter { event in
                guard case .post = event else { return false }
                return true
            }
        }

        /// Records one event, and signals the change.
        ///
        /// - Parameter event: The event.
        private func record(_ event: Event) {
            recorded.withLock { $0.append(event) }
            changes.signal()
        }

        /// Records a `PrePrompt`, and gives the decision of the test.
        ///
        /// - Parameter context: The session and the event.
        /// - Returns: The decision of the test.
        func pre(_ context: HookContext<PrePrompt>) async -> PreDecision<PrePrompt> {
            record(.pre(mailID: context.event.mailID, text: context.event.text))
            return await decide(context.event)
        }

        /// Records a `PostPrompt`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<PostPrompt>) async {
            record(.post(mailID: context.event.mailID, outcome: context.event.outcome))
        }

        /// Records a `SessionStart`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<SessionStart>) async {
            record(.start)
        }

        /// Records a `SessionEnd`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<SessionEnd>) async {
            record(.end)
        }
    }

    /// A session of a router with a dispatcher, and what the test reads.
    private struct HookedSession: HookedSessionFixture {
        /// The session under test.
        let session: any RoutedSession

        /// The backend of the session.
        let backend: Backend

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: PromptRecordingVisitor

        /// The hook-side id of a mail.
        ///
        /// - Parameter id: The id of the mail.
        /// - Returns: The id that the hook events carry.
        func hookID(_ id: MailID) -> String {
            id.description
        }

        /// The prompt hooks of the session.
        var prompts: PromptHookLedger {
            get throws {
                let actor = try #require(session as? RoutedSessionActor)
                return try #require(actor.hooks).prompts
            }
        }

        /// Waits until no mail of `ids` is screening, or until the work of
        /// the session ended (rule T1).
        ///
        /// - Parameter ids: The ids of the mail.
        /// - Throws: The error of `#require` when the work ended first.
        func waitForTheScreens(of ids: [MailID]) async throws {
            let prompts = try prompts
            try await session.stateChanges.wait(
                until: { !ids.contains(where: prompts.isScreening) }, endingWhenWorkEnds: session)
        }
    }

    /// Makes a session over a scripted backend, through a router with a
    /// dispatcher that holds `visitor`, runs `body`, and removes the
    /// temporary directory.
    ///
    /// - Parameters:
    ///   - script: What each call of the backend does, by its one-based
    ///     ordinal.
    ///   - visitor: The visitor that the dispatcher holds. `nil` makes a
    ///     dispatcher with no visitor.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withHookedSession(
        script: [Int: SessionMessagePumpTests.ScriptedCall] = [:],
        visitor: PromptRecordingVisitor? = PromptRecordingVisitor(),
        _ body: (HookedSession) async throws -> Void
    ) async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dispatcher = HookDispatcher(dataDirectory: directory.appendingPathComponent("hooks", isDirectory: true))
        let recording = visitor ?? PromptRecordingVisitor()
        if let visitor {
            dispatcher.register(visitor)
        }
        let backend = Backend(script: script)
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: SessionMessagePumpTests.PumpProbeContainer(backend: backend), cacheDir: directory,
            hooks: dispatcher)
        let session = profile.standard.makeSession()
        defer { await session.close() }
        try await body(HookedSession(session: session, backend: backend, dispatcher: dispatcher, visitor: recording))
        withExtendedLifetime(router) {}
    }

    /// A visitor that replaces the text of each `PrePrompt` with
    /// ``replacedPrompt``.
    ///
    /// - Returns: The new visitor.
    private static func replacingVisitor() -> PromptRecordingVisitor {
        PromptRecordingVisitor { event in
            .replace(PrePrompt(mailID: event.mailID, text: replacedPrompt))
        }
    }

    /// The text of each `.prompt` entry of `transcript`, in order.
    ///
    /// - Parameter transcript: The transcript of a session.
    /// - Returns: The prompt texts.
    private static func promptTexts(in transcript: Transcript) -> [String] {
        transcript.compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return TranscriptEntryMapper.flattenedText(prompt)
        }
    }

    // MARK: - One prompt

    @Test("one prompt gives SessionStart, PrePrompt and PostPrompt(answered) in order")
    func onePromptGivesStartPreAndPostInOrder() async throws {
        try await Self.withHookedSession { hooked in
            let id = try hooked.session.send(Self.firstPrompt)
            let terminal = try await hooked.session.awaitTerminal(of: id)
            await hooked.closeAndDrain()

            #expect(MailQueueFixtures.answer(of: terminal) != nil, "the message ended with \(terminal)")
            #expect(
                hooked.visitor.events == [
                    .start, .pre(mailID: hooked.hookID(id), text: Self.firstPrompt),
                    .post(mailID: hooked.hookID(id), outcome: .answered), .end,
                ])
        }
    }

    @Test("a dispatcher with no visitor screens no mail")
    func aDispatcherWithNoVisitorScreensNoMail() async throws {
        try await Self.withHookedSession(visitor: nil) { hooked in
            let id = try hooked.session.send(Self.firstPrompt)

            #expect(try !hooked.prompts.isScreening(id))
            let terminal = try await hooked.session.awaitTerminal(of: id)
            #expect(MailQueueFixtures.answer(of: terminal) != nil, "the message ended with \(terminal)")
        }
    }

    // MARK: - Batches and joins

    @Test("two mails in one batch give two PrePrompt events")
    func twoMailsInOneBatchGiveTwoPrePrompts() async throws {
        let latch = RunLatch()
        try await Self.withHookedSession(script: [1: .hold(latch)]) { hooked in
            let held = try await MailQueueFixtures.startHeldAnswer(
                Self.heldPrompt, on: hooked.session, backend: hooked.backend)
            let first = try hooked.session.send(Self.firstPrompt)
            let second = try hooked.session.send(Self.secondPrompt)
            try await hooked.waitForTheScreens(of: [first, second])
            await latch.open()
            let terminal = try await hooked.session.awaitTerminal(of: second)
            await hooked.closeAndDrain()

            let answer = try #require(MailQueueFixtures.answer(of: terminal), "the message ended with \(terminal)")
            #expect(answer.mailIds == [first, second])
            #expect(
                hooked.backend.prompts == [
                    Self.heldPrompt, Self.firstPrompt + RoutedSessionActor.messageSeparator + Self.secondPrompt,
                ])
            // Each mail runs its chain in its own task, so the two chains of the
            // batch can start in either order.
            #expect(hooked.visitor.prePromptMailIDs.sorted() == [held, first, second].map(hooked.hookID).sorted())
        }
    }

    @Test("a mail that joins a running answer gets its PrePrompt before the model gets the mail")
    func aJoiningMailGetsItsPrePromptFirst() async throws {
        let latch = RunLatch()
        // The first submission ends with a rejected tool call. The retry is a
        // continuation of the same answer, and the queued mail joins it.
        try await Self.withHookedSession(script: [1: .holdThenReject(latch)]) { hooked in
            let held = try await MailQueueFixtures.startHeldAnswer(
                Self.heldPrompt, on: hooked.session, backend: hooked.backend)
            let joining = try hooked.session.send(Self.firstPrompt)
            try await hooked.waitForTheScreens(of: [joining])
            #expect(hooked.visitor.prePromptMailIDs == [held, joining].map(hooked.hookID))
            #expect(hooked.backend.prompts == [Self.heldPrompt])
            await latch.open()
            let terminal = try await hooked.session.awaitTerminal(of: held)
            await hooked.closeAndDrain()

            let answer = try #require(MailQueueFixtures.answer(of: terminal), "the held message ended with \(terminal)")
            #expect(answer.mailIds == [held, joining])
            #expect(hooked.backend.prompts.count == 2)
            #expect(hooked.backend.prompts.last?.contains(Self.firstPrompt) == true)
        }
    }

    // MARK: - Block, replace and cancel

    @Test("a block stops the delivery: no pass, the prompt ends, and one PostPrompt(blocked)")
    func aBlockStopsTheDelivery() async throws {
        let visitor = PromptRecordingVisitor { _ in .block(reason: Self.blockReason) }
        try await Self.withHookedSession(visitor: visitor) { hooked in
            let id = try hooked.session.send(Self.firstPrompt)
            let terminal = try await hooked.session.awaitTerminal(of: id)
            await hooked.closeAndDrain()

            #expect(terminal == .cancelled(id))
            #expect(hooked.backend.prompts.isEmpty)
            #expect(
                hooked.visitor.postPrompts == [
                    .post(mailID: hooked.hookID(id), outcome: .blocked(reason: Self.blockReason))
                ])
        }
    }

    @Test("a replaced text is what the model and the transcript get")
    func aReplacedTextGoesToTheModelAndTheTranscript() async throws {
        try await Self.withHookedSession(visitor: Self.replacingVisitor()) { hooked in
            let id = try hooked.session.send(Self.firstPrompt)
            let terminal = try await hooked.session.awaitTerminal(of: id)

            #expect(MailQueueFixtures.answer(of: terminal) != nil, "the message ended with \(terminal)")
            #expect(hooked.backend.prompts == [Self.replacedPrompt])
            #expect(Self.promptTexts(in: await hooked.session.transcript) == [Self.replacedPrompt])
        }
    }

    @Test("an agent message gets a PrePrompt with its content, and a replaced content goes to the model")
    func anAgentMessageGetsAPrePromptWithItsContent() async throws {
        try await Self.withHookedSession(visitor: Self.replacingVisitor()) { hooked in
            let agentMail = Mail(sender: .session(ULID()), body: .agentMessage(from: ULID(), content: Self.firstPrompt))
            _ = try hooked.session.mail(agentMail)
            let terminal = try await hooked.session.awaitTerminal(of: agentMail.id)
            await hooked.closeAndDrain()

            #expect(MailQueueFixtures.answer(of: terminal) != nil, "the message ended with \(terminal)")
            #expect(hooked.visitor.events.contains(.pre(mailID: hooked.hookID(agentMail.id), text: Self.firstPrompt)))
            let prompt = try #require(hooked.backend.prompts.first)
            #expect(prompt.contains(Self.replacedPrompt))
            #expect(!prompt.contains(Self.firstPrompt))
        }
    }

    @Test("a cancel of a mail while its PrePrompt chain runs ends the mail as cancelled, with no pass")
    func aCancelWhileTheChainRunsEndsTheMail() async throws {
        let gate = RunLatch()
        let visitor = PromptRecordingVisitor { _ in
            await gate.waitUntilOpen()
            return .proceed
        }
        try await Self.withHookedSession(visitor: visitor) { hooked in
            let id = try hooked.session.send(Self.firstPrompt)
            try await visitor.changes.wait(
                until: { visitor.prePromptMailIDs == [hooked.hookID(id)] }, endingWhenWorkEnds: hooked.session)
            _ = hooked.session.cancel(id)
            let terminal = try await hooked.session.awaitTerminal(of: id)
            await gate.open()
            await hooked.closeAndDrain()

            #expect(terminal == .cancelled(id))
            #expect(hooked.backend.prompts.isEmpty)
            #expect(hooked.visitor.postPrompts == [.post(mailID: hooked.hookID(id), outcome: .cancelled)])
        }
    }

    // MARK: - Run mail

    /// Queues one run mail and one user message, waits for the answer that
    /// carries both, and closes the session.
    ///
    /// - Parameter hooked: The session under test.
    /// - Returns: The id of the run mail, the id of the message, and the ids
    ///   of the answer.
    /// - Throws: When the message did not end with an answer.
    private static func answerCarryingRunMail(
        on hooked: HookedSession
    ) async throws -> (runMail: MailID, message: MailID, answered: [MailID]) {
        let runMail = try await MailQueueFixtures.post(
            MailQueueFixtures.progressEvent(detail: "half of the work is done"), to: hooked.session)
        let message = try hooked.session.send(Self.firstPrompt)
        let terminal = try await hooked.session.awaitTerminal(of: message)
        await hooked.closeAndDrain()
        let answer = try #require(MailQueueFixtures.answer(of: terminal), "the message ended with \(terminal)")
        return (runMail, message, answer.mailIds)
    }

    @Test("run mail gets no PrePrompt")
    func runMailGetsNoPrePrompt() async throws {
        try await Self.withHookedSession { hooked in
            let delivery = try await Self.answerCarryingRunMail(on: hooked)

            #expect(Set(delivery.answered) == [delivery.runMail, delivery.message])
            #expect(hooked.visitor.prePromptMailIDs == [hooked.hookID(delivery.message)])
        }
    }

    @Test("run mail gets no PostPrompt")
    func runMailGetsNoPostPrompt() async throws {
        try await Self.withHookedSession { hooked in
            let delivery = try await Self.answerCarryingRunMail(on: hooked)

            #expect(Set(delivery.answered) == [delivery.runMail, delivery.message])
            #expect(
                hooked.visitor.postPrompts == [.post(mailID: hooked.hookID(delivery.message), outcome: .answered)])
        }
    }
}
