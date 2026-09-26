import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^dpn2ytt (`generation-queue.md`, section 5.8): a transcript
/// read and a fork use the settled transcript of the session, and never wait
/// for a submission that runs.
///
/// The session actor keeps a copy of its transcript as of the last settled
/// point: the end of a submission, and each tool-result boundary. A read
/// returns that copy at once, from any task. A fork seeds its child from that
/// copy at once, without the calls of an open round that have no output.
@Suite("Reads and forks use the settled transcript, with no wait for a submission")
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

        /// Appends one entry to the transcript.
        ///
        /// - Parameter entry: The entry to append.
        private func append(_ entry: Transcript.Entry) {
            entries.withLock { $0.append(entry) }
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

    /// Keeps the entries that one transcript read returned, so the test
    /// polls for them inside a bound.
    ///
    /// The read runs in a task of its own. A read that waits for a
    /// submission cannot be cancelled, so an awaited read would hang the
    /// suite instead of failing this test.
    private final class ReadBox: Sendable {
        /// The entries of the read, or `nil` while the read has not returned.
        private let stored: Mutex<[Transcript.Entry]?> = Mutex(nil)

        /// The entries of the read, or `nil` while the read has not returned.
        var entries: [Transcript.Entry]? {
            stored.withLock { $0 }
        }

        /// Keeps the entries that the read returned.
        ///
        /// - Parameter entries: The entries of the read.
        func setEntries(_ entries: [Transcript.Entry]) {
            stored.withLock { $0 = entries }
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
        _ = try await session.respond(to: Self.settledPrompt)
        let backend = try #require(container.lastBackend)

        let heldAnswer = Task { try await session.respond(to: Self.heldPrompt) }
        let heldSubmissionStarted = await BoundedWait.conditionReached("the held submission appending its prompt") {
            backend.transcriptEntries().count == Self.entriesOfOneWholeSubmission + Self.entriesOfTheHeldSubmissionSoFar
        }

        // The read comes from a task that is not the held submission, while
        // that submission still runs. The bound of `MountFixtures.poll`
        // limits the read: a read that waits for the held submission does
        // not return inside it.
        let readBox = ReadBox()
        Task { readBox.setEntries(Array(await session.transcript)) }
        let read = try await MountFixtures.poll { readBox.entries }

        await container.release.open()
        #expect(try await heldAnswer.value == HeldSubmissionBackend.answer(to: Self.heldPrompt))

        try #require(heldSubmissionStarted)
        let entries = try #require(read, "The read waited for the running submission.")
        // The settled point is the end of the first submission: its prompt and
        // its answer, and nothing of the held submission.
        #expect(entries.count == Self.entriesOfOneWholeSubmission)
        #expect(entries.map(\.id) == Array(backend.transcriptEntries().prefix(Self.entriesOfOneWholeSubmission)).map(\.id))
    }

    // MARK: - A fork from a tool of the same session

    /// A tool whose output is the marker of the step its call names.
    private struct StepMarkerTool: Tool {
        /// The model-facing name a scripted call names to reach this tool.
        static let toolName = "step-marker"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = StepMarkerTool.toolName

        /// The `Tool` description requirement. The scripted model does not
        /// read it.
        let description = "test-only tool that answers with the marker of a step"

        /// Answers with the marker of the step the call names.
        ///
        /// - Parameter arguments: The call's arguments.
        /// - Returns: The marker of the step.
        func call(arguments: AmbientToolArguments) async throws -> String {
            ScriptedToolFixture.marker(for: arguments.value)
        }
    }

    /// The child a ``OwnSessionForkingTool`` made, kept for the test to read.
    private final class ChildBox: Sendable {
        /// The session the tool forks, once the test named it.
        private let target: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// The child the fork made, or `nil` before the fork.
        private let child: Mutex<(any RoutedSession)?> = Mutex(nil)

        /// The session the tool forks, or `nil` before the test named it.
        var forkTarget: (any RoutedSession)? {
            target.withLock { $0 }
        }

        /// The child the fork made, or `nil` before the fork.
        var forkedChild: (any RoutedSession)? {
            child.withLock { $0 }
        }

        /// Names the session the tool forks.
        ///
        /// - Parameter session: The session to fork.
        func setTarget(_ session: any RoutedSession) {
            target.withLock { $0 = session }
        }

        /// Keeps the child the fork made.
        ///
        /// - Parameter session: The child.
        func setChild(_ session: any RoutedSession) {
            child.withLock { $0 = session }
        }
    }

    /// A tool whose body forks the session whose submission called it, and
    /// keeps the child in its ``ChildBox``.
    private struct OwnSessionForkingTool: Tool {
        /// The model-facing name a scripted call names to reach this tool.
        static let toolName = "own-session-fork"

        /// The output of a call whose box names no session, so a misbuilt
        /// fixture reads as a wrong answer.
        static let noTargetOutput = "no target session"

        /// What the output of a served fork opens with, before the id of the
        /// child's parent. A refusal message names the session too, so the
        /// id alone does not prove the fork was served.
        static let servedOutputPrefix = "forked from: "

        /// The output of a served fork whose child names `parentId`.
        ///
        /// - Parameter parentId: The id of the child's parent.
        /// - Returns: ``servedOutputPrefix`` followed by the id.
        static func servedOutput(parentId: ULID) -> String {
            servedOutputPrefix + parentId.description
        }

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = OwnSessionForkingTool.toolName

        /// The `Tool` description requirement. The scripted model does not
        /// read it.
        let description = "test-only tool that forks the session that called it"

        /// Where the session to fork comes from, and where the child goes.
        let box: ChildBox

        /// Forks the session of the box, and keeps the child.
        ///
        /// - Parameter arguments: The call's arguments. Not read.
        /// - Returns: ``servedOutput(parentId:)`` of the child's parent.
        /// - Throws: What the fork throws.
        func call(arguments: AmbientToolArguments) async throws -> String {
            guard let session = box.forkTarget else { return Self.noTargetOutput }
            let child = try await session.fork(workingDirectory: nil)
            box.setChild(child)
            return child.parentId.map(Self.servedOutput(parentId:)) ?? Self.noTargetOutput
        }
    }

    /// The ids of the tool calls in `entries` that no `.toolOutput` entry of
    /// `entries` answers.
    ///
    /// - Parameter entries: A transcript.
    /// - Returns: The ids of the unanswered calls, in transcript order.
    private static func unansweredCallIds(in entries: [Transcript.Entry]) -> [String] {
        let answered = Set(
            entries.compactMap { entry -> String? in
                guard case .toolOutput(let output) = entry else { return nil }
                return output.id
            })
        return entries.flatMap { entry -> [String] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.map(\.id).filter { !answered.contains($0) }
        }
    }

    /// Whether `entry` is a `.prompt` entry.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: `true` for a `.prompt` entry.
    private static func isPrompt(_ entry: Transcript.Entry) -> Bool {
        guard case .prompt = entry else { return false }
        return true
    }

    /// A tool call of `toolName` with the id `id` and no arguments.
    ///
    /// - Parameters:
    ///   - id: The id of the call.
    ///   - toolName: The name of the called tool.
    /// - Returns: The call.
    private static func call(id: String, toolName: String) -> Transcript.ToolCall {
        Transcript.ToolCall(id: id, toolName: toolName, arguments: GeneratedContent(properties: [:]))
    }

    @Test("the seed of a fork drops the unanswered calls of the last round, and its recorded count stops before the changed entry")
    func theForkSeedDropsUnansweredCallsAndStopsTheRecordedCount() {
        let answered = Self.call(id: "call-answered", toolName: StepMarkerTool.toolName)
        let unanswered = Self.call(id: "call-open", toolName: StepMarkerTool.toolName)
        let prompt = Transcript.Entry.prompt(
            Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: Self.settledPrompt))]))
        let entries: [Transcript.Entry] = [
            prompt,
            .toolCalls(Transcript.ToolCalls([answered, unanswered])),
            .toolOutput(
                Transcript.ToolOutput(
                    id: answered.id, toolName: answered.toolName,
                    segments: [.text(Transcript.TextSegment(content: ScriptedToolFixture.firstStepName))])),
        ]
        let historyOrdinal = entries.count
        let settled = SettledTranscript(
            entries: entries, recordedEntryCount: entries.count, historyOrdinal: historyOrdinal)

        let seed = settled.removingUnansweredCalls()

        #expect(Self.unansweredCallIds(in: seed.entries).isEmpty)
        #expect(seed.entries.count == entries.count)
        // The `.toolCalls` entry changed, so only the entries before it count
        // as recorded: the child records the changed entry itself.
        let entriesBeforeTheChangedEntry = [prompt].count
        #expect(seed.recordedEntryCount == entriesBeforeTheChangedEntry)
        #expect(seed.historyOrdinal == historyOrdinal)
    }

    @Test("a tool forks its own session during the submission; the fork succeeds, and the child has no tool call without an output")
    func aToolForksItsOwnSessionDuringTheSubmission() async throws {
        let box = ChildBox()
        // Round one calls the marker tool. Its result is a tool-result
        // boundary, which settles the transcript while the call has no
        // output yet. Round two calls the forking tool.
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-marker", toolName: StepMarkerTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ],
                [
                    ScriptedToolCall(
                        id: "call-fork", toolName: OwnSessionForkingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ],
            ]),
            mounting: [StepMarkerTool(), OwnSessionForkingTool(box: box)],
            tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        box.setTarget(fixture.session)

        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)

        // The answer holds the output of the forking tool: the fork was
        // served, not refused.
        #expect(answer.contains(OwnSessionForkingTool.servedOutput(parentId: fixture.session.id)))
        let child = try #require(box.forkedChild)
        #expect(child.parentId == fixture.session.id)
        let childEntries = Array(await child.transcript)
        // The child starts from the settled transcript of the running
        // submission: its prompt is there.
        #expect(childEntries.contains(where: Self.isPrompt))
        // The call of the open round had no output at the settled point, so
        // the fork removed it.
        #expect(Self.unansweredCallIds(in: childEntries).isEmpty)
    }
}
