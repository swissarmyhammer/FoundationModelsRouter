import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^dpn2ytt (`generation-queue.md`, section 5.8): a transcript
/// read uses the settled transcript of the session, and never waits for a
/// submission that runs.
///
/// The session actor keeps a copy of its transcript as of the last settled
/// point: the end of a submission, and each tool-result boundary. A read
/// returns that copy at once, from any task.
@Suite("Reads use the settled transcript, with no wait for a submission")
struct SettledTranscriptTests {
    // MARK: - Constants

    /// The suite's temp-directory prefix, so a leaked directory is
    /// attributable.
    private static let tempDirPrefix = "SettledTranscriptTests"

    /// The prompt of the submission that completes before the held one starts.
    private static let settledPrompt = "a message that settles"

    /// The prompt of the submission that the backend holds open inside its
    /// model call.
    private static let heldPrompt = "a message that stays open"

    /// How many entries one whole submission of ``HeldSubmissionBackend``
    /// appends: its `.prompt` and its `.response`.
    private static let entriesOfOneWholeSubmission = 2

    /// How many entries the held submission has appended while it is held: its
    /// `.prompt` only.
    private static let entriesOfTheHeldSubmissionSoFar = 1

    // MARK: - A backend that holds one submission open

    /// A backend that appends a `.prompt` entry, holds the call whose prompt
    /// is ``heldPrompt`` open on a latch, and then appends a `.response`
    /// entry.
    ///
    /// The transcript sits behind a `Mutex`, because the test reads it from
    /// its own task while the held call is suspended.
    private final class HeldSubmissionBackend: LanguageModelSessionBackend {
        /// The latch the held call waits on.
        private let release: RunLatch

        /// The transcript so far.
        private let entries: Mutex<[Transcript.Entry]> = Mutex([])

        /// The signal that the backend sends after it appends each entry, so
        /// a test waits for an entry with no clock.
        let changes = ChangeSignal()

        /// Makes a backend whose held call waits on `release`.
        ///
        /// - Parameter release: The latch the held call waits on.
        init(release: RunLatch) {
            self.release = release
        }

        /// Appends the prompt, holds the call when its prompt is
        /// ``SettledTranscriptTests/heldPrompt``, and appends the answer.
        ///
        /// - Parameters:
        ///   - prompt: The composed prompt of the call.
        ///   - maxTokens: The ceiling of the call. Not read.
        /// - Returns: The answer text.
        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            if prompt == SettledTranscriptTests.heldPrompt {
                await release.waitUntilOpen()
            }
            let answer = HeldSubmissionBackend.answer(to: prompt)
            append(.response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: answer))])))
            return answer
        }

        /// Not used by this suite: every submission here is a whole response.
        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { $0.finish() }
        }

        /// Not used by this suite: guided decoding is not in scope.
        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        /// A new backend over a copy of this transcript.
        func makeFork() -> any LanguageModelSessionBackend {
            HeldSubmissionBackend(release: release, entries: transcriptEntries())
        }

        /// The transcript so far.
        func transcriptEntries() -> [Transcript.Entry] {
            entries.withLock { $0 }
        }

        /// No usage: this suite reads transcripts, not counts.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }

        /// The answer this backend gives to `prompt`.
        ///
        /// - Parameter prompt: The composed prompt of the call.
        /// - Returns: The answer text.
        static func answer(to prompt: String) -> String {
            "answered: " + prompt
        }

        /// Makes a backend whose transcript starts as `entries`.
        ///
        /// - Parameters:
        ///   - release: The latch the held call waits on.
        ///   - entries: The first entries of the transcript.
        private convenience init(release: RunLatch, entries: [Transcript.Entry]) {
            self.init(release: release)
            self.entries.withLock { $0 = entries }
        }

        /// Appends one entry to the transcript, then signals ``changes``
        /// after the lock.
        ///
        /// - Parameter entry: The entry to append.
        private func append(_ entry: Transcript.Entry) {
            entries.withLock { $0.append(entry) }
            changes.signal()
        }
    }

    /// Vends one ``HeldSubmissionBackend`` for each session, and keeps the last
    /// one so a test can read its live transcript.
    private final class HeldSubmissionContainer: LoadedLLMContainer, Sendable {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The latch every held call of this container waits on.
        let release = RunLatch()

        /// The last backend this container vended.
        private let vended: Mutex<HeldSubmissionBackend?> = Mutex(nil)

        /// The last backend this container vended, or `nil` before the first.
        var lastBackend: HeldSubmissionBackend? {
            vended.withLock { $0 }
        }

        /// Vends a new backend over an empty transcript.
        ///
        /// - Parameter instructions: The instructions of the session. Not read.
        /// - Returns: The new backend.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            let backend = HeldSubmissionBackend(release: release)
            vended.withLock { $0 = backend }
            return backend
        }

        /// Vends a new backend over an empty transcript.
        ///
        /// - Parameter transcript: The seed transcript. Not read.
        /// - Returns: The new backend.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            makeSession(instructions: nil)
        }
    }

    // MARK: - A read while a submission runs

    @Test("a transcript read from another task while a submission runs returns at once, with the entries of the last settled point")
    func aReadDuringASubmissionReturnsTheSettledEntriesAtOnce() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }

        let container = HeldSubmissionContainer()
        let profile = try await RouterTestFixtures.resolveStandardProfile(
            over: container, cacheDir: directory
        ).profile
        let session = profile.standard.makeSession()
        // The held call does not end on a cancel, so the latch opens before
        // the close, also when the test throws.
        defer { await SessionFixtureLifecycle.close(session, opening: [container.release]) }
        _ = try await session.respond(to: Self.settledPrompt)
        let backend = try #require(container.lastBackend)

        let heldAnswer = Task { try await session.respond(to: Self.heldPrompt) }
        let entriesWhileHeld = Self.entriesOfOneWholeSubmission + Self.entriesOfTheHeldSubmissionSoFar
        // The wait also ends when the held answer ended (rule T1): only the
        // test opens its latch, so in a test that passes it does not end first.
        try await backend.changes.wait(
            until: { backend.transcriptEntries().count == entriesWhileHeld }, endingOnEndOf: heldAnswer)

        // The read comes from a task that is not the held submission, while
        // that submission still runs. Only the test opens the latch of the
        // held submission, and it does so after the read returns. Thus a read
        // that waited for the held submission never returns, and the test
        // stops here: a stack of the test process shows it.
        let read = Task { Array(await session.transcript) }
        let entries = await read.value

        await container.release.open()
        #expect(try await heldAnswer.value == HeldSubmissionBackend.answer(to: Self.heldPrompt))

        // The settled point is the end of the first submission: its prompt and
        // its answer, and nothing of the held submission.
        #expect(entries.count == Self.entriesOfOneWholeSubmission)
        #expect(entries.map(\.id) == Array(backend.transcriptEntries().prefix(Self.entriesOfOneWholeSubmission)).map(\.id))
    }
}
