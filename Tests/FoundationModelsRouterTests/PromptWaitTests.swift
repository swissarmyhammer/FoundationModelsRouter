import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the waits for a prompt of a ``PromptCountingBackend`` (rule T1):
/// each wait also ends on its failure event, and the test then fails by an
/// assertion.
///
/// The failure event is the end of a task, a session that becomes idle, or
/// the end of the work of a session. Each wait runs on
/// ``SessionMessagePumpTests/PumpProbeBackend``. The suite
/// needs no network and no GPU.
@Suite("The waits for a prompt also end on the failure event")
struct PromptWaitTests {
    /// The backend the suite scripts.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "PromptWaitTests"

    /// The production change that makes this test fail: a wait that reads
    /// only the count of the prompts. That wait does not end when the task
    /// ends, so it records no issue.
    @Test("a wait for a prompt fails the test and returns when the task ended and no prompt came")
    func aWaitEndsOnTheEndOfTheTask() async {
        let backend = Backend(script: [:])
        let ended = Task {}

        await withKnownIssue("the task ended before a prompt reached the backend") {
            try await backend.waitForPrompts(1, endingOnEndOf: ended)
        }
        #expect(backend.prompts.isEmpty)
    }

    /// Makes a session over a backend with no script, runs `body` on them,
    /// and then closes the session and removes its directory, also when
    /// `body` throws (rule T1). No mail and no pump of the session run, so
    /// the session is idle and has no work.
    ///
    /// - Parameter body: The test, with the backend and the session.
    /// - Throws: What the make of the session or `body` throws.
    private static func withIdleSession(_ body: (Backend, any RoutedSession) async throws -> Void) async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = Backend(script: [:])
        let (session, profile) = try await MailQueueFixtures.makeSession(over: backend, dir: dir)
        defer { await session.close() }

        try await body(backend, session)
        withExtendedLifetime(profile) {}
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the count of the prompts. A session with no mail and no pump is
    /// idle, and that wait does not end, so it records no issue.
    @Test("a wait for a prompt fails the test and returns when the session is idle and no prompt came")
    func aWaitEndsWhenTheSessionIsIdle() async throws {
        try await Self.withIdleSession { backend, session in
            await withKnownIssue("the session became idle before a prompt reached the backend") {
                try await MailQueueFixtures.waitForPrompts(1, on: backend, endingWhenIdle: session)
            }
            #expect(backend.prompts.isEmpty)
        }
    }

    /// The production change that makes this test fail: a wait that reads
    /// only the count of the prompts. The idle wait of a session with no work
    /// (``RoutedSession/awaitIdle()``) returns at once, and that wait does
    /// not end, so it records no issue.
    @Test("a wait for a prompt fails the test and returns when the session has no work and no prompt came")
    func aWaitEndsWhenTheWorkOfTheSessionEnds() async throws {
        try await Self.withIdleSession { backend, session in
            await withKnownIssue("the work of the session ended before a prompt reached the backend") {
                try await MailQueueFixtures.waitForPrompts(1, on: backend, endingWhenWorkEnds: session)
            }
            #expect(backend.prompts.isEmpty)
        }
    }
}
