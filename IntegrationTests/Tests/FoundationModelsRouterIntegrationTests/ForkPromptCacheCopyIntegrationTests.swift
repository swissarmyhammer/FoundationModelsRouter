import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import MLXFoundationModels

/// The standard model of this suite: `Qwen2.5-3B-Instruct-4bit`, 1.6 GB on
/// disk, the model of `SummarizerPromptCacheIntegrationTests`. Its layers are
/// all attention layers, so a copy rewinds to the token where the render of
/// the fork parts from the render of the source. It does not reason, so the
/// template keeps each earlier answer as the model wrote it, and it calls
/// tools.
private let forkCopyStandardModel: ModelRef = "mlx-community/Qwen2.5-3B-Instruct-4bit"

/// The flash and decision model of this suite: Qwen3 1.7B, the flash model
/// of `PromptCacheBudgetIntegrationTests`. The two generation slots of one
/// profile never use the same model.
private let forkCopyFlashModel: ModelRef = "mlx-community/Qwen3-1.7B-4bit"

/// The working context of ``forkCopyProfile``, in tokens.
private let forkCopyContextTokens = 4096

/// The profile of this suite. Each fork runs on the standard slot of its
/// source.
private let forkCopyProfile = ProfileDefinition(
    name: "fork-prompt-cache-copy",
    description: "A small attention-only standard model for the fork cache copy, and small companions.",
    standard: [forkCopyStandardModel],
    flash: [forkCopyFlashModel],
    embedding: [RealModels.embedding],
    decision: [forkCopyFlashModel],
    context: forkCopyContextTokens
)

/// Gated real-model coverage for D205 (f): a fork starts with a copy of the
/// MLX prompt cache of its source (task ^jx6ng3r).
///
/// ## What it proves
///
/// - The first call of a fork reuses the history up to the cut from the
///   copy, for `.lastCompletedTurn`, `.callingToolCall` and
///   `.historyPosition(n)`. The bound is the tokens of the history that the
///   source left in its cache, less ``templateSeamTokens``.
/// - With no copy, the first call of a fork reads its whole prompt and
///   answers correctly, and its greedy reply equals the reply of a fork with
///   the copy.
/// - The fork and the source are independent: a prompt to one does not
///   change the cache of the other.
/// - The copy counts in the prompt-cache usage, and the budget that the
///   router sends after the copy holds the resident bytes.
/// - A close of the fork releases only the copy; a close of the source keeps
///   the copy.
/// - A fork that a host launcher builds gets the copy too.
///
/// ## Why the coverage is gated
///
/// `ForkPromptCacheCopyTests` and `MLXPromptCacheCopyTests` in the unit
/// target prove the copy call, its outcomes, the log and the budget send over
/// a recording model, with no GPU. Only the executor of mlx-swift-lm keeps a
/// real prompt cache. Its store is one store for the whole process, so this
/// suite holds the GPU alone (`.exclusiveRealModel`), and each test releases
/// each entry of the store first.
@Suite(
    "Gated real-model coverage: a fork starts with a copy of the MLX prompt cache of its source (D205 (f))",
    .serialized,
    .exclusiveRealModel
)
struct ForkPromptCacheCopyIntegrationTests {
    /// The instructions of each source that does not fork itself.
    private static let instructions = "You are a terse assistant. Follow each instruction exactly."

    /// The instructions of the source that forks itself from a tool call.
    private static let checkpointInstructions = """
        You are a terse assistant. When the user asks for a checkpoint, call the \
        `\(CheckpointForkingTool.toolName)` tool exactly once, then reply with just DONE.
        """

    /// The code word that the first prompt of each source gives.
    private static let codeWord = "ALPHA-7"

    /// The prompt of the first turn of each source.
    private static let firstSourcePrompt = "My code word is \(codeWord). Reply with just OK."

    /// The prompt of the second turn of each source.
    private static let secondSourcePrompt = "My favorite color is green. Reply with just OK."

    /// The prompt that makes the source fork itself from a tool call.
    private static let checkpointPrompt = "Save a checkpoint named start."

    /// The first prompt of each fork. The history of each fork holds the
    /// answer.
    private static let forkPrompt = "What is my code word? Reply with just the code word."

    /// The first prompt of the fork of the tool call, whose history holds
    /// only the prompt of the call.
    private static let arithmeticPrompt = "What is 2 + 2? Reply with just the number."

    /// The prompt of a later turn of a source.
    private static let sourceFollowUpPrompt = "What is my favorite color? Reply with just the color."

    /// The prompt of a later turn of a fork.
    private static let forkFollowUpPrompt = "Say my code word one more time. Reply with just the code word."

    /// The tokens at the end of the cached history that the render of the
    /// next prompt can change: the end marker of the last entry, the role
    /// marker of the next entry, and the generation prompt. A call that
    /// reuses at least the history less these tokens did not prefill the
    /// history again.
    private static let templateSeamTokens = 16

    /// The ceiling of each reply.
    private static let replyTokenCeiling = GatedRealModelBudget.responseTokenCeiling

    // MARK: - Fixture

    /// A source that answered its two turns.
    private struct AnsweredSource {
        /// The source.
        let session: RoutedSessionActor

        /// The answer of the first turn.
        let first: MeasuredAnswer

        /// The answer of the second turn.
        let second: MeasuredAnswer
    }

    /// A router of this suite with the resolved profile.
    private struct Fixture {
        /// The router, its pool, its probe and its folder.
        let isolated: IsolatedPoolRouter

        /// The resolved profile.
        let profile: LanguageModelProfile

        /// The session directory of the router.
        var directory: RouterSessionDirectory { isolated.router.sessionDirectory }

        /// Makes a source on the standard slot with `instructions` and
        /// `tools`.
        ///
        /// - Parameters:
        ///   - instructions: The instructions of the source.
        ///   - tools: The tools of the source.
        /// - Returns: The source.
        /// - Throws: The `#require` failure for a session that is not a
        ///   Router session actor.
        func makeSource(
            instructions: String = ForkPromptCacheCopyIntegrationTests.instructions, tools: [any Tool] = []
        ) throws -> RoutedSessionActor {
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(instructions: instructions, tools: tools))
            return try #require(session as? RoutedSessionActor)
        }

        /// Makes a source that answered ``firstSourcePrompt`` and then
        /// ``secondSourcePrompt``.
        ///
        /// - Returns: The source and its two answers.
        /// - Throws: What an answer throws.
        func makeAnsweredSource() async throws -> AnsweredSource {
            let source = try makeSource()
            let first = try await ForkPromptCacheCopyIntegrationTests.answer(
                ForkPromptCacheCopyIntegrationTests.firstSourcePrompt, on: source)
            let second = try await ForkPromptCacheCopyIntegrationTests.answer(
                ForkPromptCacheCopyIntegrationTests.secondSourcePrompt, on: source)
            return AnsweredSource(session: source, first: first, second: second)
        }

        /// Forks `source` at `cut`, and gives the live fork.
        ///
        /// - Parameters:
        ///   - source: The source.
        ///   - cut: The cut of the fork.
        /// - Returns: The live fork.
        /// - Throws: The error of the fork, or the `#require` failure when the
        ///   fork is not live.
        func fork(_ source: any RoutedSession, at cut: SessionForkCut) async throws -> any RoutedSession {
            let summary = try await directory.fork(
                SessionForkRequest(sourceID: source.id, cut: cut, forker: .user(clientID: "fork-copy-test")))
            return try #require(directory.session(id: summary.id))
        }
    }

    /// Resolves ``forkCopyProfile`` on a router over a pool of its own,
    /// releases each entry of the prompt-cache store, and runs `body`. The
    /// body closes each session that it made, so the pool evicts each model
    /// at the end.
    ///
    /// - Parameters:
    ///   - probe: The machine probe of the router.
    ///   - body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withFixture(
        probe: any MachineProbe = SystemMachineProbe(), _ body: (Fixture) async throws -> Void
    ) async throws {
        let isolated = IsolatedPoolRouter(
            label: "ForkPromptCacheCopyIntegrationTests", samplingMode: .greedy, probe: probe, recordsDurably: true)
        defer { isolated.removeRoot() }
        await ExecutorPromptCacheStore.current.evict(modelID: nil)
        try await isolated.withResolved(forkCopyProfile) { profile in
            try await body(Fixture(isolated: isolated, profile: profile))
        }
    }

    /// Answers `prompt` on `session` with the reply ceiling of the suite.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - session: The session that answers.
    /// - Returns: The answer.
    /// - Throws: What the answer throws.
    private static func answer(_ prompt: String, on session: any RoutedSession) async throws -> MeasuredAnswer {
        try await MeasuredAnswer.answer(to: prompt, on: session, maxTokens: replyTokenCeiling)
    }

    /// The input tokens that the first call of `answer` reused from the
    /// prompt cache.
    ///
    /// - Parameter answer: The answer.
    /// - Returns: The reused tokens.
    /// - Throws: The `#require` failure for an answer with no call, or a call
    ///   with no cached count.
    private static func cachedTokensOfFirstCall(of answer: MeasuredAnswer) throws -> Int {
        let firstCall = try #require(answer.calls.first)
        return try #require(firstCall.tokensCached)
    }

    /// The tokens that a call must reuse when the cache holds `history`: the
    /// history less ``templateSeamTokens``.
    ///
    /// - Parameter history: The tokens of the cached history.
    /// - Returns: The least reused tokens.
    private static func reuseBound(of history: Int) -> Int {
        history - templateSeamTokens
    }

    /// The tokens of the history that the last call of `answer` left in the
    /// prompt cache.
    ///
    /// - Parameter answer: The answer.
    /// - Returns: The tokens.
    /// - Throws: The `#require` failure for an answer with no call.
    private static func historyTokens(after answer: MeasuredAnswer) throws -> Int {
        try #require(answer.calls.last).historyTokens
    }

    /// The prompt-cache usage once no entry is being written to disk.
    ///
    /// - Returns: The usage.
    private static func settledPromptCacheUsage() async -> PromptCacheUsage {
        await ExecutorPromptCacheStore.current.waitForSpills()
        let usage = await MLXLanguageModel.promptCacheUsage
        return PromptCacheUsage(
            memoryBytes: usage.memoryBytes, spillingBytes: usage.spillingBytes, diskBytes: usage.diskBytes)
    }

    /// The history position of the second prompt of `session`: a cut there
    /// keeps the first turn and not the second.
    ///
    /// - Parameter session: The session.
    /// - Returns: The position.
    /// - Throws: The `#require` failure for a session with fewer than two
    ///   prompts.
    private static func positionOfSecondPrompt(of session: any RoutedSession) async throws -> Int {
        let entries = Array(await session.transcript)
        let promptPositions = entries.indices.filter {
            if case .prompt = entries[$0] { return true }
            return false
        }
        return try #require(promptPositions.dropFirst().first)
    }

    /// The room for one and a half entries of `entryBytes`: room for one
    /// entry, and not for two.
    ///
    /// - Parameter entryBytes: The bytes of one entry.
    /// - Returns: The room, in bytes.
    private static func roomForOneAndAHalf(of entryBytes: Int) -> Int64 {
        Int64(entryBytes + entryBytes / 2)
    }

    /// Closes each session of `sessions`.
    ///
    /// - Parameter sessions: The sessions that the test made.
    private static func close(_ sessions: [any RoutedSession]) async {
        for session in sessions {
            await session.close()
        }
    }

    // MARK: - The cut

    /// The production change that makes this test fail: a fork that copies
    /// no cache, or a fork whose passes bind the key of the source.
    @Test("a fork at the last completed turn reuses the whole history from the copy")
    func aForkAtTheLastCompletedTurnReusesTheHistory() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)

            let answer = try await Self.answer(Self.forkPrompt, on: fork)

            let history = try Self.historyTokens(after: source.second)
            #expect(try Self.cachedTokensOfFirstCall(of: answer) >= Self.reuseBound(of: history))
            await Self.close([source.session, fork])
        }
    }

    /// The production change that makes this test fail: a fork that copies
    /// no cache. The copy has the second turn too, and the first pass of the
    /// fork rewinds it.
    @Test("a fork at a history position reuses the history up to the position from the copy")
    func aForkAtAHistoryPositionReusesTheHistoryUpToThePosition() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let position = try await Self.positionOfSecondPrompt(of: source.session)
            let fork = try await fixture.fork(source.session, at: .historyPosition(position))

            let answer = try await Self.answer(Self.forkPrompt, on: fork)

            let history = try Self.historyTokens(after: source.first)
            #expect(try Self.cachedTokensOfFirstCall(of: answer) >= Self.reuseBound(of: history))
            #expect(answer.reply.contains(Self.codeWord))
            await Self.close([source.session, fork])
        }
    }

    /// The production change that makes this test fail: a copy that the
    /// pass of the source refuses while the tool body runs (`.sourceInUse`).
    /// The pass that emitted the tool call ended before the tool body, so
    /// the copy gets the cache of the source.
    @Test("a fork at the calling tool call reuses the history up to the call from the copy")
    func aForkAtTheCallingToolCallReusesTheHistoryUpToTheCall() async throws {
        try await Self.withFixture { fixture in
            let tool = CheckpointForkingTool(directory: fixture.directory)
            let source = try fixture.makeSource(instructions: Self.checkpointInstructions, tools: [tool])
            let sourceAnswer = try await Self.answer(Self.checkpointPrompt, on: source)
            let forkID = try #require(tool.madeForkID)
            let fork = try #require(fixture.directory.session(id: forkID))

            let answer = try await Self.answer(Self.arithmeticPrompt, on: fork)

            let toolCallPass = try #require(sourceAnswer.calls.first { $0.entryKind == .toolCall })
            #expect(try Self.cachedTokensOfFirstCall(of: answer) >= Self.reuseBound(of: toolCallPass.tokensIn))
            await Self.close([source, fork])
        }
    }

    // MARK: - No copy

    /// The production change that makes this test fail: a fork that fails,
    /// or answers wrongly, when its source has no cache to copy.
    @Test("a fork whose source has no cache reads its whole prompt and answers correctly")
    func aForkWithNoCopyReadsItsWholePromptAndAnswers() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            await source.session.releasePromptCache()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)

            let answer = try await Self.answer(Self.forkPrompt, on: fork)

            #expect(try Self.cachedTokensOfFirstCall(of: answer) == 0)
            #expect(answer.reply.contains(Self.codeWord))
            await Self.close([source.session, fork])
        }
    }

    /// The production change that makes this test fail: a copy that the
    /// fork reads past the point where its render parts from the render of
    /// the source, so its greedy reply changes.
    @Test("the greedy reply of a fork with the copy equals the reply of a fork with no copy")
    func theGreedyReplyWithTheCopyEqualsTheReplyWithNoCopy() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let copied = try await fixture.fork(source.session, at: .lastCompletedTurn)
            let copiedAnswer = try await Self.answer(Self.forkPrompt, on: copied)
            await source.session.releasePromptCache()
            let uncopied = try await fixture.fork(source.session, at: .lastCompletedTurn)

            let uncopiedAnswer = try await Self.answer(Self.forkPrompt, on: uncopied)

            #expect(try Self.cachedTokensOfFirstCall(of: copiedAnswer) > 0)
            #expect(try Self.cachedTokensOfFirstCall(of: uncopiedAnswer) == 0)
            #expect(copiedAnswer.reply == uncopiedAnswer.reply)
            await Self.close([source.session, copied, uncopied])
        }
    }

    // MARK: - Independence

    /// The production change that makes this test fail: a fork whose passes
    /// write into the cache of the source. The fork parts from the source
    /// after the first turn, so its tokens would replace the second turn of
    /// the source.
    @Test("a prompt to the fork leaves the cache of the source: the next turn of the source is a full hit")
    func aPromptToTheForkLeavesTheCacheOfTheSource() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let position = try await Self.positionOfSecondPrompt(of: source.session)
            let fork = try await fixture.fork(source.session, at: .historyPosition(position))
            _ = try await Self.answer(Self.forkPrompt, on: fork)

            let sourceAnswer = try await Self.answer(Self.sourceFollowUpPrompt, on: source.session)

            let history = try Self.historyTokens(after: source.second)
            #expect(try Self.cachedTokensOfFirstCall(of: sourceAnswer) >= Self.reuseBound(of: history))
            await Self.close([source.session, fork])
        }
    }

    /// The production change that makes this test fail: a source whose
    /// passes write into the cache of the fork.
    @Test("a prompt to the source leaves the cache of the fork: the next turn of the fork is a full hit")
    func aPromptToTheSourceLeavesTheCacheOfTheFork() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)
            let firstForkAnswer = try await Self.answer(Self.forkPrompt, on: fork)
            _ = try await Self.answer(Self.sourceFollowUpPrompt, on: source.session)

            let forkAnswer = try await Self.answer(Self.forkFollowUpPrompt, on: fork)

            let history = try Self.historyTokens(after: firstForkAnswer)
            #expect(try Self.cachedTokensOfFirstCall(of: forkAnswer) >= Self.reuseBound(of: history))
            await Self.close([source.session, fork])
        }
    }

    // MARK: - Memory

    /// The production change that makes this test fail: a fork that sends no
    /// budget after the copy, so the copy and the source both stay in memory
    /// over the budget; or a copy that the usage does not count.
    ///
    /// The test gives the prompt cache room for one and a half entries of
    /// the source after the source answered. The copy adds a second entry of
    /// the same bytes. The budget that the fork sends after the copy then
    /// moves the least recently used entry, the source, to disk.
    @Test("the usage counts the copy, and the resident prompt-cache bytes stay in the budget")
    func theUsageCountsTheCopyAndTheResidentBytesStayInTheBudget() async throws {
        let probe = AdjustableWorkingSetProbe()
        try await Self.withFixture(probe: probe) { fixture in
            let source = try await fixture.makeAnsweredSource()
            let before = await Self.settledPromptCacheUsage()
            #expect(before.diskBytes == 0 && before.memoryBytes > 0)
            let workingSet = fixture.isolated.pool.footprint.totalBytes + Self.roomForOneAndAHalf(of: before.memoryBytes)
            probe.setWorkingSet(workingSet)

            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)

            let after = await Self.settledPromptCacheUsage()
            let budget = await ExecutorPromptCacheStore.current.memoryBudgetBytes
            #expect(after.memoryBytes == before.memoryBytes, "the copy stays in memory, and the source goes to disk")
            #expect(after.diskBytes > 0, "the copy pushed the source to disk")
            #expect(after.residentBytes <= budget)
            #expect(fixture.isolated.pool.footprint.totalBytes + Int64(after.residentBytes) <= workingSet)
            await Self.close([source.session, fork])
        }
    }

    // MARK: - Release

    /// The production change that makes this test fail: a close of the fork
    /// that releases the cache of the source, or that keeps the copy.
    @Test("a close of the fork releases the copy and keeps the cache of the source")
    func aCloseOfTheForkReleasesTheCopyAndKeepsTheSource() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let before = await Self.settledPromptCacheUsage()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)
            let withCopy = await Self.settledPromptCacheUsage()

            await fork.close()

            let afterClose = await Self.settledPromptCacheUsage()
            let sourceAnswer = try await Self.answer(Self.sourceFollowUpPrompt, on: source.session)
            let history = try Self.historyTokens(after: source.second)
            #expect(withCopy.totalBytes == 2 * before.totalBytes)
            #expect(afterClose.totalBytes == before.totalBytes)
            #expect(try Self.cachedTokensOfFirstCall(of: sourceAnswer) >= Self.reuseBound(of: history))
            await Self.close([source.session])
        }
    }

    /// The production change that makes this test fail: a close of the
    /// source that releases the copy of the fork too.
    @Test("a close of the source keeps the copy of the fork")
    func aCloseOfTheSourceKeepsTheCopy() async throws {
        try await Self.withFixture { fixture in
            let source = try await fixture.makeAnsweredSource()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)
            let withCopy = await Self.settledPromptCacheUsage()

            await source.session.close()

            let afterClose = await Self.settledPromptCacheUsage()
            let answer = try await Self.answer(Self.forkPrompt, on: fork)
            let history = try Self.historyTokens(after: source.second)
            #expect(2 * afterClose.totalBytes == withCopy.totalBytes)
            #expect(try Self.cachedTokensOfFirstCall(of: answer) >= Self.reuseBound(of: history))
            await Self.close([fork])
        }
    }

    // MARK: - The host launcher

    /// The production change that makes this test fail: a copy on the
    /// default build path only, and not in the build of a host launcher.
    @Test("a fork that a host launcher builds reuses the history from the copy")
    func aForkThroughTheHostLauncherReusesTheHistory() async throws {
        try await Self.withFixture { fixture in
            await fixture.directory.use(launcher: ForkBuildingLauncher())
            let source = try await fixture.makeAnsweredSource()
            let fork = try await fixture.fork(source.session, at: .lastCompletedTurn)

            let answer = try await Self.answer(Self.forkPrompt, on: fork)

            let history = try Self.historyTokens(after: source.second)
            #expect(try Self.cachedTokensOfFirstCall(of: answer) >= Self.reuseBound(of: history))
            await Self.close([source.session, fork])
        }
    }
}
