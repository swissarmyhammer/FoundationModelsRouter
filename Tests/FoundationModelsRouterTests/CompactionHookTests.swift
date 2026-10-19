import Foundation
import FoundationModels
import FoundationModelsHooks
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Holds the compaction hooks of a session (task ^ne3mrvh): each compaction
/// gives one `CompactionStarted` and one `CompactionEnded`, with the id of
/// its ``SessionEvent/compactionStarted(_:)`` event.
///
/// Both triggers go through the one compaction handler: a requested
/// compaction (``RoutedSession/compact(prompt:budget:)``) and an automatic
/// compaction inside an answer. The tests use the scripted compaction
/// fixtures of ``AnswerCancellationTests``, through a router with a
/// dispatcher that holds a ``CompactionRecordingVisitor``. Each test closes
/// the session and calls `dispatcher.drain()` before it reads the post
/// events, because a post event arrives on a task of the dispatcher.
@Suite("Compaction hooks: CompactionStarted and CompactionEnded")
struct CompactionHookTests {
    /// The fixtures and the stubs of the suite.
    private typealias Fixtures = AnswerCancellationTests

    /// The prompt of the answer that compacts before its first submission.
    private static let compactingPrompt = "compacts-first"

    /// The summary that each summarizer call gives, short enough that the
    /// compaction applies it.
    private static let shortSummary = "short summary"

    // MARK: - Fixtures

    /// A visitor that records each compaction event, in the order of
    /// delivery.
    final class CompactionRecordingVisitor: HookVisitor {
        /// One recorded event.
        enum Event: Equatable {
            /// A `CompactionStarted`, with the id and the reason of its
            /// compaction.
            case started(compactionID: String, reason: String)
            /// A `CompactionEnded`, with the id and the outcome of its
            /// compaction.
            case ended(compactionID: String, outcome: CompactionOutcome)
        }

        /// The recorded events.
        private let recorded = Mutex<[Event]>([])

        /// The recorded events, in the order of delivery.
        var events: [Event] {
            recorded.withLock { $0 }
        }

        /// Records a `CompactionStarted`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<CompactionStarted>) async {
            let event = Event.started(compactionID: context.event.compactionID, reason: context.event.reason)
            recorded.withLock { $0.append(event) }
        }

        /// Records a `CompactionEnded`.
        ///
        /// - Parameter context: The session and the event.
        func post(_ context: HookContext<CompactionEnded>) async {
            let event = Event.ended(compactionID: context.event.compactionID, outcome: context.event.outcome)
            recorded.withLock { $0.append(event) }
        }
    }

    /// A warmed-up compaction session of a router with a dispatcher, and
    /// what the test reads.
    private struct HookedSession: HookedSessionFixture {
        /// The fixture behind the session.
        let fixture: Fixtures.Fixture

        /// The session under test.
        let session: any RoutedSession

        /// The dispatcher of the router.
        let dispatcher: HookDispatcher

        /// The visitor registered on ``dispatcher``.
        let visitor: CompactionRecordingVisitor
    }

    /// Makes a warmed-up compaction session through a router with a
    /// dispatcher that holds a new ``CompactionRecordingVisitor``, runs
    /// `body`, closes the session, and removes the temporary directory.
    ///
    /// The visitor is on the dispatcher before the session starts, so the
    /// session sends its `SessionStart` and the dispatcher keeps a queue for
    /// it. Each summarizer call replies with ``shortSummary``, so a
    /// compaction applies.
    ///
    /// - Parameters:
    ///   - metersTriggeringFill: Whether the next answer compacts before its
    ///     first submission
    ///     (``AnswerCancellationTests/makeCompactionTriggeredSession(_:budget:metersTriggeringFill:)``).
    ///   - body: The test.
    /// - Throws: What the warm-up or `body` throws.
    private static func withHookedSession(
        metersTriggeringFill: Bool = false,
        _ body: (HookedSession) async throws -> Void
    ) async throws {
        let directory = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let dispatcher = HookDispatcher(dataDirectory: directory.appendingPathComponent("hooks", isDirectory: true))
        let visitor = CompactionRecordingVisitor()
        dispatcher.register(visitor)
        let fixture = try await Fixtures.makeFixture(cacheDir: directory, hooks: dispatcher)
        fixture.hook.reply = { Fixtures.isSummarizerCall($0) ? shortSummary : nil }
        let session = try await Fixtures.makeCompactionTriggeredSession(
            fixture, budget: Fixtures.summarizingCompactionBudget, metersTriggeringFill: metersTriggeringFill)
        defer { await session.close() }
        try await body(HookedSession(fixture: fixture, session: session, dispatcher: dispatcher, visitor: visitor))
    }

    // MARK: - Completed

    /// The production change that makes this test fail: a requested
    /// compaction that sends no hook event, or a hook event whose id is not
    /// the id of the ``SessionEvent/compactionStarted(_:)`` event.
    @Test("a requested compaction gives CompactionStarted and then CompactionEnded(completed) with the same id")
    func aRequestedCompactionGivesStartedAndCompleted() async throws {
        try await Self.withHookedSession { hooked in
            let id = Fixtures.requestSummarizingCompaction(of: hooked.session)
            let terminal = try await hooked.session.awaitTerminal(of: id)
            await hooked.closeAndDrain()

            let result = try #require([terminal].compactionResults.first, "the compaction ended with \(terminal)")
            #expect(
                hooked.visitor.events == [
                    .started(compactionID: id.description, reason: CompactionReason.requested.rawValue),
                    .ended(
                        compactionID: id.description,
                        outcome: .completed(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter)),
                ])
        }
    }

    /// The production change that makes this test fail: hook events that
    /// only the requested compaction sends, and not the automatic one.
    @Test("an automatic compaction inside an answer gives CompactionStarted and then CompactionEnded(completed)")
    func anAutomaticCompactionGivesStartedAndCompleted() async throws {
        try await Self.withHookedSession(metersTriggeringFill: true) { hooked in
            let answerEvents = try await collect(await hooked.session.streamEvents(to: Self.compactingPrompt))
            await hooked.closeAndDrain()

            let start = try #require(answerEvents.compactionStarts.first)
            let result = try #require(answerEvents.compactionResults.first)
            #expect(start.reason == .triggerReached)
            #expect(
                hooked.visitor.events == [
                    .started(compactionID: start.id, reason: CompactionReason.triggerReached.rawValue),
                    .ended(
                        compactionID: start.id,
                        outcome: .completed(tokensBefore: result.tokensBefore, tokensAfter: result.tokensAfter)),
                ])
        }
    }

    // MARK: - Failed and cancelled

    /// The production change that makes this test fail: a failed
    /// compaction that sends no `CompactionEnded`, or that sends it with
    /// another outcome.
    @Test("a compaction that fails gives CompactionEnded(failed) with the message of the failure")
    func aFailedCompactionGivesFailed() async throws {
        try await Self.withHookedSession { hooked in
            hooked.fixture.hook.midAnswer = { prompt in
                guard Fixtures.isSummarizerCall(prompt) else { return }
                throw Fixtures.ProbeError.summarizerFailed
            }
            let id = Fixtures.requestSummarizingCompaction(of: hooked.session)
            _ = try await hooked.session.awaitTerminal(of: id)
            await hooked.closeAndDrain()

            #expect(
                hooked.visitor.events == [
                    .started(compactionID: id.description, reason: CompactionReason.requested.rawValue),
                    .ended(
                        compactionID: id.description,
                        outcome: .failed(message: String(describing: Fixtures.ProbeError.summarizerFailed))),
                ])
        }
    }

    /// The production change that makes this test fail: a cancelled
    /// compaction whose `CompactionEnded` says `failed`, or that the
    /// `SessionEnd` of the close overtakes, so the dispatcher drops it.
    @Test("a close during a compaction gives CompactionEnded(cancelled)")
    func aCloseDuringACompactionGivesCancelled() async throws {
        try await Self.withHookedSession { hooked in
            let inside = AsyncSemaphore(value: 0)
            let sawCancellation = Fixtures.suspendInsideCancellationAwareTool(
                hooked.fixture, suspendingOn: Fixtures.firstSummarizerCall(), insideTool: inside)
            let session = hooked.session
            let id = Fixtures.requestSummarizingCompaction(of: session)
            let ending = Task { _ = try? await session.awaitTerminal(of: id) }
            defer { ending.cancel() }
            try await RecordedWaitResult.wait(forPermitOf: inside, endingOnEndOf: ending)
            // The summarizer call ends only on a cancel, so close returns
            // only when it cancels the call (rule T1: the wait also ends on
            // the end of the close).
            let closing = Task { await session.close() }
            try await RecordedWaitResult.wait(for: sawCancellation, endingOnEndOf: closing)
            await closing.value
            await hooked.dispatcher.drain()

            #expect(
                hooked.visitor.events == [
                    .started(compactionID: id.description, reason: CompactionReason.requested.rawValue),
                    .ended(compactionID: id.description, outcome: .cancelled),
                ])
        }
    }

    // MARK: - No dispatcher

    /// The production change that makes this test fail: a compaction that
    /// needs the hooks of the session, so a session of a router with no
    /// dispatcher does not compact.
    @Test("a session of a router with no dispatcher compacts as before")
    func aSessionWithNoDispatcherCompacts() async throws {
        let directory = Fixtures.makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await Fixtures.makeFixture(cacheDir: directory)
        fixture.hook.reply = { Fixtures.isSummarizerCall($0) ? Self.shortSummary : nil }
        let session = try await Fixtures.makeCompactionTriggeredSession(
            fixture, budget: Fixtures.summarizingCompactionBudget, metersTriggeringFill: false)
        defer { await session.close() }

        #expect(try #require(session as? RoutedSessionActor).hooks == nil)
        let terminal = try await session.awaitTerminal(of: Fixtures.requestSummarizingCompaction(of: session))
        let result = try #require([terminal].compactionResults.first, "the compaction ended with \(terminal)")
        #expect(result.summaryEntryId != nil)
    }
}
