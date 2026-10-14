import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``RoutedSession/awaitAnswer(of:)``: the wait that gives a caller
/// of ``RoutedSession/mail(_:)`` or ``RoutedSession/send(_:)-(String)`` the
/// answer of its mail, or the typed error of a failed answer.
///
/// Each test runs in a fixed order, with no clock. A test that must keep
/// mail in the queue holds the running answer inside its model call with a
/// semaphore (``AnswerCancellationTests/makeFixture(cacheDir:appendsPromptBeforeToolCall:pool:)``),
/// and a signal ends before the test reads its effect.
@Suite("awaitAnswer(of:) gives the answer of a mail, or the error of its failed answer")
struct AwaitAnswerTests {
    /// The prompt of the message whose model call throws a context overflow.
    private static let overflowPrompt = "overflow-question"

    /// The prompt of the message whose model call the test holds open.
    private static let heldPrompt = "held-question"

    /// The prompt of the first message that waits in the queue.
    private static let firstQueuedPrompt = "first-queued-question"

    /// The prompt of the second message that waits in the queue.
    private static let secondQueuedPrompt = "second-queued-question"

    /// The prompt of a message that the model answers at once.
    private static let plainPrompt = "plain-question"

    // MARK: - Fixtures

    /// Makes a session over the hooked stub backend, with no budget. Thus a
    /// context overflow ends the answer at once, with no compaction and no
    /// retry.
    ///
    /// - Parameter dir: The cache and recording root of the router.
    /// - Returns: The fixture and the session.
    private static func makeSession(
        dir: URL
    ) async throws -> (fixture: AnswerCancellationTests.Fixture, session: any RoutedSession) {
        let fixture = try await AnswerCancellationTests.makeFixture(cacheDir: dir)
        return (fixture, fixture.model.makeSession())
    }

    /// Installs a hook that throws a context overflow in the model call of
    /// ``overflowPrompt``, and lets each other model call answer.
    ///
    /// - Parameter fixture: The fixture whose hook to install into.
    private static func overflowOnTheOverflowPrompt(_ fixture: AnswerCancellationTests.Fixture) {
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix(overflowPrompt) else { return }
            throw AnswerCancellationTests.makeStubContextOverflow()
        }
    }

    /// Installs a hook that holds the model call of ``heldPrompt`` until
    /// `release` is signalled, and lets each other model call answer.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose hook to install into.
    ///   - insideModelCall: Signalled when the held model call runs.
    ///   - release: The signal that lets the held model call answer.
    private static func holdTheHeldPrompt(
        _ fixture: AnswerCancellationTests.Fixture, insideModelCall: AsyncSemaphore, release: AsyncSemaphore
    ) {
        fixture.hook.midAnswer = { prompt in
            guard prompt.hasSuffix(heldPrompt) else { return }
            insideModelCall.signal()
            await release.wait()
        }
    }

    /// Whether `error` is the context overflow of the stub hook.
    ///
    /// - Parameter error: The error a wait threw, or `nil`.
    /// - Returns: `true` for `LanguageModelError.contextSizeExceeded`.
    private static func isContextOverflow(_ error: LanguageModelError?) -> Bool {
        if case .contextSizeExceeded? = error {
            return true
        }
        return false
    }

    // MARK: - answered and answerFailed

    @Test("a mail whose answer fails with a context overflow gives the typed error through awaitAnswer(of:)")
    func aFailedAnswerGivesItsOriginalError() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        Self.overflowOnTheOverflowPrompt(fixture)

        let id = try session.send(Self.overflowPrompt)
        let caught = await #expect(throws: LanguageModelError.self) {
            try await session.awaitAnswer(of: id)
        }

        #expect(Self.isContextOverflow(caught), "the wait threw \(String(describing: caught))")
        await session.close()
    }

    @Test("a call after the failed answer ended, also after close(), still gets the typed error")
    func aCallAfterTheAnswerEndedGetsTheSameError() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        Self.overflowOnTheOverflowPrompt(fixture)

        let id = try session.send(Self.overflowPrompt)
        // The terminal event came, so the answer ended before each later call.
        let terminal = try await session.awaitTerminal(of: id)
        #expect([terminal].answerFailures.map(\.mailIds) == [[id]])

        let afterTheEnd = await #expect(throws: LanguageModelError.self) {
            try await session.awaitAnswer(of: id)
        }
        await session.close()
        let afterTheClose = await #expect(throws: LanguageModelError.self) {
            try await session.awaitAnswer(of: id)
        }

        #expect(Self.isContextOverflow(afterTheEnd), "the wait threw \(String(describing: afterTheEnd))")
        #expect(Self.isContextOverflow(afterTheClose), "the wait threw \(String(describing: afterTheClose))")
    }

    @Test("an answered mail gives the SessionAnswer of its answered event")
    func anAnsweredMailGivesItsAnswer() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, session) = try await Self.makeSession(dir: dir)

        let id = try session.send(Self.plainPrompt)
        let answer = try await session.awaitAnswer(of: id)

        #expect(answer.mailIds == [id])
        #expect(answer.reply == "ok-\(Self.plainPrompt)")
        #expect(try await session.awaitTerminal(of: id) == .answered(answer))
        await session.close()
    }

    @Test("two mails that one answer delivers each give that one SessionAnswer, with both ids")
    func mailThatSharesAnAnswerGetsThatAnswer() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let insideModelCall = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        Self.holdTheHeldPrompt(fixture, insideModelCall: insideModelCall, release: release)

        let held = try session.send(Self.heldPrompt)
        await insideModelCall.wait()
        // The pump runs the held answer, so both messages wait in the queue
        // and the next submission delivers them together.
        let first = try session.send(Self.firstQueuedPrompt)
        let second = try session.send(Self.secondQueuedPrompt)
        release.signal()

        let firstAnswer = try await session.awaitAnswer(of: first)
        let secondAnswer = try await session.awaitAnswer(of: second)

        #expect(firstAnswer.mailIds == [first, second])
        #expect(secondAnswer == firstAnswer)
        #expect(try await session.awaitAnswer(of: held).mailIds == [held])
        await session.close()
    }

    // MARK: - cancelled and lost

    @Test("cancel(_:) of a mail before its delivery makes awaitAnswer(of:) throw CancellationError")
    func aCancelBeforeDeliveryThrowsCancellationError() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        let insideModelCall = AsyncSemaphore(value: 0)
        let release = AsyncSemaphore(value: 0)
        Self.holdTheHeldPrompt(fixture, insideModelCall: insideModelCall, release: release)

        let held = try session.send(Self.heldPrompt)
        await insideModelCall.wait()
        let queued = try session.send(Self.firstQueuedPrompt)
        let cancel = session.cancel(queued)
        #expect(try await session.awaitTerminal(of: cancel) == .signalDone(cancel))

        await #expect(throws: CancellationError.self) {
            _ = try await session.awaitAnswer(of: queued)
        }
        release.signal()
        #expect(try await session.awaitAnswer(of: held).mailIds == [held])
        await session.close()
    }

    @Test("a mail that a restore reports as lost makes awaitAnswer(of:) throw CancellationError")
    func aLostMailThrowsCancellationError() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, session) = try await Self.makeSession(dir: dir)
        let sessionActor = try #require(session as? RoutedSessionActor)
        let lost = MailID()

        // The call that a restore makes for each mail that a crash cut off.
        await sessionActor.reportLostMail([lost])

        await #expect(throws: CancellationError.self) {
            _ = try await session.awaitAnswer(of: lost)
        }
        await session.close()
    }

    // MARK: - close() and the bound of the ledger

    @Test("close() ends a wait for a mail with no terminal event with MailRefusal.closed, and a later call throws it at once")
    func theCloseEndsAWaitWithClosed() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, session) = try await Self.makeSession(dir: dir)
        let unknown = MailID()

        // The wait starts before or after the close; both orders end with
        // the same refusal.
        let wait = Task { try await session.awaitAnswer(of: unknown) }
        await session.close()

        await #expect(throws: MailRefusal.closed) {
            _ = try await wait.value
        }
        await #expect(throws: MailRefusal.closed) {
            _ = try await session.awaitAnswer(of: unknown)
        }
    }

    @Test("a call after ledgerCapacity later terminal ids waits until close() and then throws MailRefusal.closed")
    func aCallAfterTheLedgerBoundWaitsUntilClose() async throws {
        let dir = AnswerCancellationTests.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fixture, session) = try await Self.makeSession(dir: dir)
        Self.overflowOnTheOverflowPrompt(fixture)

        let id = try session.send(Self.overflowPrompt)
        _ = try await session.awaitTerminal(of: id)
        // Each signal ends with one terminal event, and the ledger keeps the
        // terminal ids of mail and of signals together. The signals run in
        // order, so the end of the last one comes after each other end.
        let signals = (0..<SessionOutputHub.ledgerCapacity).map { _ in session.cancel(MailID()) }
        let last = try #require(signals.last)
        #expect(try await session.awaitTerminal(of: last) == .signalDone(last))

        let wait = Task { try await session.awaitAnswer(of: id) }
        await session.close()

        await #expect(throws: MailRefusal.closed) {
            _ = try await wait.value
        }
    }
}
