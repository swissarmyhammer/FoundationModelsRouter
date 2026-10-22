import Foundation
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// A vended session writes its first `index.md` with the facts of its
/// ``SessionConfiguration``, holds its record where synchronous code reads
/// it, and rewrites the frontmatter through `updateFacts` with the body a
/// host wrote kept (ROUTER-1). A failed save is logged and the session goes
/// on. The record marks the first submission and moves at each submission.
@Suite struct SessionIndexRecordingTests {
    /// The text a host writes below the frontmatter of an `index.md`.
    private static let hostBody = "\n# Notes\nhost text\n"

    /// The permissions of a session folder nothing can be written into.
    private static let readOnlyFolderPermissions = 0o500

    /// The permissions a session folder gets back after a test made it
    /// read-only, so the temporary directory can be removed.
    private static let writableFolderPermissions = 0o700

    /// The message of the error a dropped save of an `index.md` logs.
    private static let droppedSaveMessage = "dropping a save of a session index.md"

    /// The pause between two submissions, so the millisecond clock of the
    /// record moves between them.
    private static let clockStep: Duration = .milliseconds(5)

    /// Runs `body` with a resolved profile over a durable recording root.
    ///
    /// - Parameter body: The work to run with the resolved profile.
    private static func withProfile(
        _ body: (LanguageModelProfile) async throws -> Void
    ) async throws {
        try await SessionFactsFixtures.withRecordingProfile(prefix: "SessionIndexRecordingTests", body)
    }

    /// Vends one root session with the fact configuration under a durable
    /// recording root, runs `body` with it, and closes it.
    ///
    /// - Parameter body: The work to run with the session and the id of the
    ///   session that started it.
    private static func withVendedSession(
        _ body: (RoutedSessionActor, ULID) async throws -> Void
    ) async throws {
        try await withProfile { profile in
            let startedBy = ULID.generate()
            let session = profile.standard.makeSession(
                configuration: SessionFactsFixtures.configuration(startedBy: startedBy))
            let actor = try #require(session as? RoutedSessionActor)
            do {
                try await body(actor, startedBy)
            } catch {
                await session.close()
                throw error
            }
            await session.close()
        }
    }

    /// Writes ``hostBody`` below the frontmatter of the `index.md` of a
    /// session folder, as a host does.
    ///
    /// - Parameter directory: The session folder.
    /// - Throws: The error of the read or the write.
    private static func appendHostBody(in directory: URL) throws {
        let file = SessionIndexFile.url(in: directory)
        let text = try String(contentsOf: file, encoding: .utf8) + hostBody
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The body of the `index.md` of a session folder: the text after its
    /// frontmatter.
    ///
    /// - Parameter directory: The session folder.
    /// - Returns: The body.
    /// - Throws: The error of the read.
    private static func body(in directory: URL) throws -> String {
        FrontmatterDocument.split(
            text: try String(contentsOf: SessionIndexFile.url(in: directory), encoding: .utf8)
        ).body
    }

    /// Reads `facts` from a synchronous function, so the read compiles only
    /// when it needs no `await`.
    ///
    /// - Parameter session: The session.
    /// - Returns: The facts of the session.
    private static func readFactsSynchronously(of session: any RoutedSession) -> SessionFacts {
        session.facts
    }

    /// The `index.md` of a new session holds the facts of its configuration,
    /// and `facts`, read with no `await`, equals it.
    @Test func aVendedSessionWritesTheFactsOfItsConfiguration() async throws {
        try await Self.withVendedSession { session, startedBy in
            let written = try #require(try SessionIndexFile.read(in: session.recordingDirectory)).facts

            #expect(written == SessionFactsFixtures.expectedFacts(startedBy: startedBy))
            #expect(Self.readFactsSynchronously(of: session) == written)
        }
    }

    /// `updateFacts` rewrites the frontmatter of `index.md`, keeps the body a
    /// host wrote byte for byte, updates `facts`, and returns the new value.
    @Test func updateFactsRewritesTheIndexAndKeepsTheBody() async throws {
        try await Self.withVendedSession { session, _ in
            let directory = session.recordingDirectory
            try Self.appendHostBody(in: directory)
            let bodyBefore = try Self.body(in: directory)

            let updated = session.updateFacts { facts in
                facts.tags.insert("urgent")
                facts.title = "Renamed"
            }
            let onDisk = try #require(try SessionIndexFile.read(in: directory)).facts

            #expect(updated.tags == SessionFactsFixtures.tags.union(["urgent"]))
            #expect(updated.title == "Renamed")
            #expect(session.facts == updated)
            #expect(onDisk == updated)
            #expect(bodyBefore.hasSuffix(Self.hostBody))
            #expect(try Self.body(in: directory) == bodyBefore)
        }
    }

    /// A save of `index.md` that fails is logged once as an error, and the
    /// session goes on: `updateFacts` returns the new facts and the session
    /// holds them, while the file on disk keeps the old ones.
    @Test func aFailedSaveIsLoggedAndTheSessionGoesOn() async throws {
        try await Self.withVendedSession { session, _ in
            let directory = session.recordingDirectory
            let before = try #require(try SessionIndexFile.read(in: directory)).facts
            try FileManager.default.setAttributes(
                [.posixPermissions: Self.readOnlyFolderPermissions], ofItemAtPath: directory.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: Self.writableFolderPermissions], ofItemAtPath: directory.path)
            }

            let (updated, errors) = try await TelemetryCapture.run(forbidding: []) { context in
                let updated = session.updateFacts { facts in facts.title = "Renamed" }
                let errors = context.logRecords.filter {
                    $0.level == .error && "\($0.message)".contains(Self.droppedSaveMessage)
                }
                return (updated, errors)
            }
            let onDisk = try #require(try SessionIndexFile.read(in: directory)).facts

            #expect(updated.title == "Renamed")
            #expect(session.facts == updated)
            #expect(onDisk == before)
            #expect(onDisk.title == SessionFactsFixtures.title)
            #expect(errors.count == 1)
        }
    }

    /// A session vended with no fact field writes empty facts.
    @Test func aSessionWithNoFactFieldWritesEmptyFacts() async throws {
        try await Self.withProfile { profile in
            let session = profile.standard.makeSession(configuration: SessionConfiguration())

            let written = try #require(try SessionIndexFile.read(in: session.recordingDirectory)).facts

            #expect(written == SessionFacts())
            #expect(session.facts == SessionFacts())
            await session.close()
        }
    }

    /// A vended session that has had no prompt has no first activity, in its
    /// record and in its `index.md`.
    @Test func aSessionWithNoPromptHasNoFirstActivity() async throws {
        try await Self.withVendedSession { session, _ in
            let onDisk = try #require(try SessionIndexFile.read(in: session.recordingDirectory))

            #expect(session.record.firstActivityAt == nil)
            #expect(onDisk.firstActivityAt == nil)
        }
    }

    /// The first submission of a session sets its first activity, in its
    /// record and in its `index.md`, and its last activity is not before it.
    @Test func theFirstSubmissionSetsTheFirstActivity() async throws {
        try await Self.withVendedSession { session, _ in
            _ = try await session.respond(to: "hello")

            let held = session.record
            let onDisk = try #require(try SessionIndexFile.read(in: session.recordingDirectory))
            let firstActivity = try #require(held.firstActivityAt)

            #expect(onDisk.firstActivityAt == firstActivity)
            #expect(held.updatedAt >= firstActivity)
            #expect(onDisk.updatedAt == held.updatedAt)
        }
    }

    /// A second submission moves the last activity of the session later and
    /// leaves its first activity as it was.
    @Test func aLaterSubmissionMovesTheLastActivityAndKeepsTheFirst() async throws {
        try await Self.withVendedSession { session, _ in
            _ = try await session.respond(to: "hello")
            let afterFirst = session.record
            let firstActivity = try #require(afterFirst.firstActivityAt)
            try await Task.sleep(for: Self.clockStep)

            _ = try await session.respond(to: "again")
            let afterSecond = session.record
            let onDisk = try #require(try SessionIndexFile.read(in: session.recordingDirectory))

            #expect(afterSecond.updatedAt > afterFirst.updatedAt)
            #expect(afterSecond.firstActivityAt == firstActivity)
            #expect(onDisk.updatedAt == afterSecond.updatedAt)
            #expect(onDisk.firstActivityAt == firstActivity)
        }
    }

    /// The answer of each submission and of the summarizer call of the
    /// compaction test. Several answers of it are much larger than one copy,
    /// so the summary makes the live context smaller.
    private static let compactionAnswerText = String(
        repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)

    /// How many answers the session gives before it compacts: enough copies
    /// of ``compactionAnswerText`` that the one summary makes the live
    /// context smaller.
    private static let answersBeforeCompaction = 6

    /// A compaction of a live, durable session counts one more compaction in
    /// its record, in memory and in its `index.md`.
    @Test("a compaction of a live session counts one more compaction in its index.md")
    func aCompactionOfALiveSessionCountsOneMoreCompaction() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: "SessionIndexRecordingTests")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = RetainingLLMContainer(responseText: Self.compactionAnswerText)
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory.appendingPathComponent("cache"),
            recordingsDir: directory.appendingPathComponent("recordings"))
        let session = profile.standard.makeSession()
        do {
            let actor = try #require(session as? RoutedSessionActor)
            try await driveAnswers(Self.answersBeforeCompaction, on: session)
            let before = try #require(try SessionIndexFile.read(in: actor.recordingDirectory))
            #expect(actor.record.compactionCount == 0)
            #expect(before.compactionCount == 0)

            let backend = try #require(container.lastBackend)
            let result = try await session.compactAndAwait(
                budget: summarizingCompactionBudget(for: backend.transcriptEntries()))
            #expect(result.stagesApplied == [Summarization.stageName])

            let onDisk = try #require(try SessionIndexFile.read(in: actor.recordingDirectory))
            #expect(actor.record.compactionCount == 1)
            #expect(onDisk.compactionCount == 1)
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        withExtendedLifetime(router) {}
    }
}
