import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The recap write of a session directory (D206) when the write fails or a
/// close comes during the write.
///
/// The write starts, writes the record, and only then removes what the
/// recap covers and sends `factsChanged`, when no cancel came during the
/// write. A write that throws keeps the prompts for the next recap and logs
/// the failure of the write. A close during the write of a live session
/// throws nothing and logs no failure: the record keeps the recap, the
/// directory sends no `factsChanged`, and the close drops the prompts.
///
/// The recapper of the directory under test gets the turns from the test
/// (``SessionRecapper/feedTurn(of:prompt:reply:toolCalls:getsRecap:)``), and
/// a fake flash model (``FakeRecapHost``). Its write is the write of the
/// directory (``FakeRecapHost/host(writingThrough:)``). A manual clock ends
/// the idle time, so the test has no sleep.
@Suite("RouterSessionDirectory: a recap write that fails, or that a close meets")
struct RouterSessionDirectoryRecapWriteTests {
    /// The parts of one test.
    struct Fixture {
        /// The two routers over one recordings folder.
        let pair: SessionDirectoryRouterPair

        /// The directory under test.
        let directory: RouterSessionDirectory

        /// The clock of the recapper of ``directory``.
        let clock: ManualRunClock

        /// The fake flash model, and the count of the writes that started.
        let host: FakeRecapHost

        /// The recapper of ``directory``.
        var recapper: SessionRecapper { directory.recapper }

        /// Gives the recapper one turn of the session `id`, with a tool call
        /// and the prompt `prompt`, and lets the session in for a recap.
        ///
        /// - Parameters:
        ///   - id: The session id.
        ///   - prompt: The user prompt of the turn.
        func feedTurn(of id: ULID, prompt: String) {
            host.admit(id)
            recapper.feedTurn(
                of: id, prompt: prompt, reply: RouterSessionDirectoryRecapWriteTests.reply,
                toolCalls: [RouterSessionDirectoryRecapWriteTests.toolCall])
        }

        /// Moves the clock past the idle time, and waits until no recap job
        /// waits, queues or runs.
        ///
        /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
        func passTheIdleTime() async throws {
            clock.advance(by: SessionRecapper.idleTime)
            try await waitForTheEndOfTheJobs()
        }

        /// Waits until no recap job waits, queues or runs.
        ///
        /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
        func waitForTheEndOfTheJobs() async throws {
            try await recapper.jobChanges.wait(until: { recapper.jobCount == 0 })
        }
    }

    // MARK: - Constants

    /// The prompt of the first turn.
    private static let firstPrompt = "fix the failing parser test"

    /// The prompt of the second turn.
    private static let secondPrompt = "now update the change log"

    /// The reply of each turn.
    private static let reply = "I fixed the test."

    /// The output of the fake flash model.
    private static let recap = "Fixed the failing parser test; the tests pass now."

    /// The tool call of each turn, which makes the turn not trivial.
    private static let toolCall = ToolCallEntry(
        id: "call-1", name: "edit", argumentsJSON: #"{"path":"Sources/Parser.swift"}"#, status: .completed,
        summary: nil)

    /// The permissions of a session folder nothing can be written into.
    private static let readOnlyFolderPermissions = 0o500

    /// The permissions a session folder gets back after a test made it
    /// read-only, so the temporary directory can be removed.
    private static let writableFolderPermissions = 0o700

    /// The start of the message of the log record of a recap write that
    /// failed.
    private static let writeFailureMessage = "a recap write failed"

    /// The word that each log record of a failure of a recap holds.
    private static let failureWord = "failed"

    /// An event no session sends, which a test sends to mark the end of what
    /// it reads.
    private static let marker = SessionDirectoryEvent.archived(id: ULID.generate())

    // MARK: - Helpers

    /// Makes the two routers, and gives the recapper of one directory of
    /// them a manual clock and a fake flash model that writes through that
    /// directory.
    ///
    /// - Parameters:
    ///   - isLive: `true` for the directory of the recording router, which
    ///     holds the live sessions; `false` for the directory of the reading
    ///     router, where each recorded session is not live.
    ///   - afterStart: What the test does after the start of each write and
    ///     before the write of the record, with the directory and the session
    ///     id. The default does nothing.
    /// - Returns: The fixture.
    /// - Throws: What the resolve of the profiles throws.
    private static func makeFixture(
        isLive: Bool, afterStart: @escaping @Sendable (RouterSessionDirectory, ULID) -> Void = { _, _ in }
    ) async throws -> Fixture {
        let pair = try await SessionDirectoryRouterPair.make(prefix: "RouterSessionDirectoryRecapWriteTests")
        let directory = isLive ? pair.recordingRouter.sessionDirectory : pair.directory
        let clock = ManualRunClock()
        directory.useRecapClock(clock)
        let host = FakeRecapHost(output: recap, changes: directory.recapper.jobChanges)
        directory.recapper.use(
            host: host.host(writingThrough: directory, afterStart: { [directory] id in afterStart(directory, id) }))
        return Fixture(pair: pair, directory: directory, clock: clock, host: host)
    }

    /// Makes a fixture over the reading directory and a recorded session
    /// that is not live there, and runs one recap of a turn with
    /// ``firstPrompt`` while the folder of the session is read-only: the
    /// save of its `index.md` fails.
    ///
    /// - Returns: The fixture and the id of the recorded session.
    /// - Throws: What the resolve of the profiles or a change of the
    ///   permissions throws, or ``ConditionNeverHeld``.
    private static func failTheFirstRecordedWrite() async throws -> (Fixture, ULID) {
        let fixture = try await makeFixture(isLive: false)
        let recorded = await fixture.pair.recordClosedRoot()
        await fixture.pair.useRoot(of: recorded.recordingDirectory)
        let folder = recorded.recordingDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: readOnlyFolderPermissions], ofItemAtPath: folder)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: writableFolderPermissions], ofItemAtPath: folder)
        }
        fixture.feedTurn(of: recorded.id, prompt: firstPrompt)
        try await fixture.passTheIdleTime()
        return (fixture, recorded.id)
    }

    /// The log records of a failure of a recap of the session `id`.
    ///
    /// - Parameters:
    ///   - context: The capture of the test.
    ///   - id: The session id.
    /// - Returns: The records.
    private static func failureRecords(in context: TelemetryCapture.Context, of id: ULID) -> [String] {
        context.logRecords.compactMap { record in
            let message = "\(record.message)"
            let session = record.metadata[RouterTelemetry.LogMetadataKey.sessionId].map { "\($0)" }
            guard message.contains(failureWord), session == id.description else { return nil }
            return message
        }
    }

    /// The recaps of the `factsChanged` events in `events`.
    ///
    /// - Parameter events: Directory events.
    /// - Returns: The recaps.
    private static func factsChangedRecaps(in events: [SessionDirectoryEvent]) -> [String?] {
        events.compactMap { event in
            guard case .factsChanged(let summary) = event else { return nil }
            return summary.recap
        }
    }

    // MARK: - A write that throws

    /// The production change that makes this test fail: a write that
    /// removes the prompts of the recap before the save of the record, so a
    /// save that fails loses them.
    @Test("a recorded recap write whose save fails keeps the prompts for the next recap")
    func aRecordedWriteWhoseSaveFailsKeepsThePrompts() async throws {
        let (fixture, id) = try await Self.failTheFirstRecordedWrite()

        fixture.feedTurn(of: id, prompt: Self.secondPrompt)
        try await fixture.passTheIdleTime()

        #expect(fixture.host.backend.calls.last?.prompt.contains(Self.firstPrompt) == true)
        fixture.pair.remove()
    }

    /// The production change that makes this test fail: a write failure
    /// that is logged as a failure of the call of the model, or not at all.
    @Test("a recorded recap write whose save fails logs the failure of the write")
    func aRecordedWriteWhoseSaveFailsLogsTheFailure() async throws {
        let (outcome, logs) = try await TelemetryCapture.run(forbidding: []) { context in
            (try await Self.failTheFirstRecordedWrite(), context)
        }

        logs.expectLogged(
            containing: Self.writeFailureMessage,
            metadata: [RouterTelemetry.LogMetadataKey.sessionId: outcome.1.description])
        outcome.0.pair.remove()
    }

    // MARK: - A close during the write

    /// The production change that makes this test fail: a live write that
    /// reads the live summary after the write, so a close that comes between
    /// the read of the live session and the write makes the write throw, and
    /// the recapper logs a failure for a recap that is in the record.
    ///
    /// The close is the unregister of the session, which a close of the
    /// session runs; the host of the test runs it right after the start of
    /// the write, before the write of the record. The rule of a cancel during
    /// the write holds: the record keeps the recap, and the directory sends
    /// no `factsChanged`.
    @Test("a close during the live recap write logs no failure, and the record keeps the recap")
    func aCloseDuringTheLiveWriteLogsNoFailure() async throws {
        let fixture = try await Self.makeFixture(isLive: true, afterStart: { directory, id in directory.unregister(id) })
        let session = fixture.pair.recordingProfile.standard.makeSession(configuration: SessionConfiguration())
        var events = fixture.directory.events().makeAsyncIterator()

        let failures = try await TelemetryCapture.run(forbidding: []) { context in
            fixture.feedTurn(of: session.id, prompt: Self.firstPrompt)
            try await fixture.passTheIdleTime()
            return Self.failureRecords(in: context, of: session.id)
        }
        fixture.directory.emit(Self.marker)
        let recaps = Self.factsChangedRecaps(in: await events.next(through: Self.marker))

        #expect(failures.isEmpty)
        let recordedRecap = try SessionRecordFixtures.recordOnDisk(in: session.recordingDirectory).facts.recap
        #expect(fixture.host.startedWrites == 1 && recordedRecap == Self.recap && recaps.isEmpty)
        await session.close()
        fixture.pair.remove()
    }
}
