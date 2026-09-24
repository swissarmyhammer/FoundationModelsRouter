import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^tpsc0nf: the render that the session sends to the model, and the
/// context token counter of the session, restart at each compaction.
///
/// - The render of a generation call is the instructions, then the latest
///   compaction snapshot, then the messages since that snapshot.
/// - The recorded transcript keeps each entry and each snapshot. A compaction
///   removes and replaces no recorded entry.
/// - The counter is the size of the render. It goes up, restarts at a
///   compaction from the instructions and the snapshot, and goes up again. It
///   is never the sum of the generation calls of a tool loop.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a scripted model. No GPU is in the loop.
@Suite("The render to the model and its token counter restart at each compaction")
struct CompactionRenderCounterTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "CompactionRenderCounterTests"

    /// The instructions of each session of this suite.
    private static let instructions = "You answer the questions of the render probe."

    /// The working context of each render probe session: large, so that no
    /// automatic rule acts on it.
    private static let probeContextTokens = 100_000

    /// The working context of each metered session, so a fill is an exact
    /// fraction of a round number.
    private static let meteredContextTokens = 1_000

    /// The counter the scripted model and the tests measure with.
    private static let counter = CharacterTokenCounter()

    /// The executor of the render probe model, for its texts.
    private typealias Probe = RenderProbeLanguageModel.Executor

    /// The prompt of the first turn. Each prompt is long, so that a
    /// compaction to half of the context has room for the snapshot.
    private static let firstQuestion =
        "Question one: describe the state of the render probe at this step of the work, in full detail."

    /// The prompt of the second turn.
    private static let secondQuestion =
        "Question two: describe the state of the render probe at this step of the work, in full detail."

    /// The prompt of the third turn.
    private static let thirdQuestion =
        "Question three: describe the state of the render probe at this step of the work, in full detail."

    /// The prompts of the three turns, in order.
    private static let questions = [firstQuestion, secondQuestion, thirdQuestion]

    /// The text of the first snapshot of a session.
    private static let firstSnapshot = Probe.snapshotText(number: 1)

    /// The text of the second snapshot of a session.
    private static let secondSnapshot = Probe.snapshotText(number: 2)

    /// The count of the entries of the render after one compaction and one
    /// prompt: the instructions, the snapshot, and the prompt.
    private static let renderEntriesAfterCompaction = 3

    /// The count of the tool calls of the tool-loop turn. The turn then makes
    /// one more generation call, which answers.
    private static let toolLoopRounds = 2

    /// The output token ceiling of the ceiling-stop turn.
    private static let ceiling = 50

    /// The budget of the ceiling-stop session.
    private static let ceilingStopBudget = TokenBudget(limit: meteredContextTokens, trigger: 0.8, target: 0.5)

    /// The usage of the calls of the ceiling-stop turn: two calls that ask for
    /// the tool, then a call that stops at ``ceiling``. The sum of the calls is
    /// over the trigger of ``ceilingStopBudget``. The last call is under it.
    private static let ceilingStopCalls = [
        MeteredGenerationCall(tokensIn: 300, tokensOut: 10),
        MeteredGenerationCall(tokensIn: 350, tokensOut: 10),
        MeteredGenerationCall(tokensIn: 400, tokensOut: ceiling),
    ]

    /// Builds a render probe fixture.
    ///
    /// - Parameter toolRoundsPerTurn: The count of the tool calls that each
    ///   turn makes before it answers.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProbe(toolRoundsPerTurn: Int) async throws -> RenderProbeSessionFixture {
        try await RenderProbeSessionFixture.make(
            instructions: instructions, toolRoundsPerTurn: toolRoundsPerTurn,
            context: probeContextTokens, tempDirPrefix: tempDirPrefix)
    }

    /// Compacts `session` against a budget whose target is under its live
    /// context, so that the summarizer call runs.
    ///
    /// - Parameter session: The session to compact.
    /// - Returns: What the compaction did.
    /// - Throws: What the compaction throws.
    @discardableResult
    private static func compact(_ session: RoutedSession) async throws -> CompactionResult {
        try await session.compact(budget: summarizingCompactionBudget(for: Array(await session.transcript)))
    }

    /// The counter of `session`, in tokens, read back from its fill.
    ///
    /// - Parameters:
    ///   - session: The session to read.
    ///   - contextTokens: The working context the session resolved at.
    /// - Returns: The counter, in tokens.
    private static func counterTokens(of session: RoutedSession, contextTokens: Int) async -> Int {
        Int((await session.contextFill * Double(contextTokens)).rounded())
    }

    /// The text of each entry of `transcript` that the model reads.
    ///
    /// - Parameter transcript: The transcript to read.
    /// - Returns: One text for each entry, in order.
    private static func texts(of transcript: Transcript) -> [String] {
        transcript.map(CharacterTokenCounter.content(of:))
    }

    /// The newest render that the probe model received.
    ///
    /// - Parameter fixture: The fixture whose log to read.
    /// - Returns: The transcript of the newest generation call.
    /// - Throws: When the model received no call.
    private static func newestRender(of fixture: RenderProbeSessionFixture) throws -> Transcript {
        try #require(fixture.log.renders.last)
    }

    /// The size of the newest render of `fixture` plus the answer to `prompt`:
    /// the context after the last generation call of that turn.
    ///
    /// - Parameters:
    ///   - fixture: The fixture whose log to read.
    ///   - prompt: The prompt of the turn.
    /// - Returns: The size, in tokens.
    /// - Throws: When the model received no call.
    private static func contextAfterAnswer(of fixture: RenderProbeSessionFixture, to prompt: String) throws -> Int {
        try counter.count(newestRender(of: fixture)) + counter.count(Probe.answerText(to: prompt))
    }

    /// Whether `entry` is an `.instructions` entry.
    private static func isInstructions(_ entry: Transcript.Entry) -> Bool {
        if case .instructions = entry { return true }
        return false
    }

    // MARK: - The render

    @Test("after a compaction, the render is the instructions, the snapshot, and the messages since it")
    func renderAfterCompactionHoldsInstructionsSnapshotAndNewMessages() async throws {
        let fixture = try await Self.makeProbe(toolRoundsPerTurn: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: Self.firstQuestion)
        _ = try await fixture.session.respond(to: Self.secondQuestion)

        let compaction = try await Self.compact(fixture.session)
        _ = try await fixture.session.respond(to: Self.thirdQuestion)

        let render = Array(try Self.newestRender(of: fixture))
        let texts = Self.texts(of: Transcript(entries: render))
        #expect(render.count == Self.renderEntriesAfterCompaction)
        let leading = try #require(render.first)
        #expect(Self.isInstructions(leading))
        #expect(texts.first == Self.instructions)
        #expect(render.dropFirst().first?.id == compaction.summaryEntryId)
        #expect(texts.dropFirst().first?.contains(Self.firstSnapshot) == true)
        #expect(texts.last == Self.thirdQuestion)
        let whole = texts.joined()
        #expect(!whole.contains(Self.firstQuestion))
        #expect(!whole.contains(Self.secondQuestion))
    }

    @Test("after two compactions, the render holds the instructions and the second snapshot, not the first")
    func renderAfterTwoCompactionsHoldsOnlyTheLatestSnapshot() async throws {
        let fixture = try await Self.makeProbe(toolRoundsPerTurn: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: Self.firstQuestion)
        let first = try await Self.compact(fixture.session)
        _ = try await fixture.session.respond(to: Self.secondQuestion)
        let second = try await Self.compact(fixture.session)

        _ = try await fixture.session.respond(to: Self.thirdQuestion)

        let render = Array(try Self.newestRender(of: fixture))
        let whole = Self.texts(of: Transcript(entries: render)).joined()
        let leading = try #require(render.first)
        #expect(Self.isInstructions(leading))
        #expect(whole.hasPrefix(Self.instructions))
        #expect(render.contains { $0.id == second.summaryEntryId })
        #expect(!render.contains { $0.id == first.summaryEntryId })
        #expect(whole.contains(Self.secondSnapshot))
        #expect(!whole.contains(Self.firstSnapshot))
        #expect(!whole.contains(Self.firstQuestion))
        #expect(!whole.contains(Self.secondQuestion))
        #expect(whole.contains(Self.thirdQuestion))
    }

    // MARK: - The recorded transcript

    @Test("after two compactions, the recorded transcript keeps each earlier entry and both snapshots, unchanged")
    func recordedTranscriptKeepsEveryEntryAcrossTwoCompactions() async throws {
        let fixture = try await Self.makeProbe(toolRoundsPerTurn: 0)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        _ = try await fixture.session.respond(to: Self.firstQuestion)
        let beforeFirst = await fixture.recorder.events
        let first = try await Self.compact(fixture.session)
        _ = try await fixture.session.respond(to: Self.secondQuestion)
        let beforeSecond = await fixture.recorder.events
        let second = try await Self.compact(fixture.session)
        _ = try await fixture.session.respond(to: Self.thirdQuestion)

        let journal = await fixture.recorder.events
        #expect(Array(journal.prefix(beforeFirst.count)) == beforeFirst)
        #expect(Array(journal.prefix(beforeSecond.count)) == beforeSecond)
        let recordedIds = journal.compactMap { $0.entry?.entryId }
        #expect(recordedIds.contains { $0 == first.summaryEntryId })
        #expect(recordedIds.contains { $0 == second.summaryEntryId })
        let recordedPrompts = journal.filter { $0.kind == .prompt }.compactMap(\.text)
        let recordedAnswers = journal.filter { $0.kind == .response }.compactMap(\.text)
        for question in Self.questions {
            #expect(recordedPrompts.contains { $0.contains(question) })
            #expect(recordedAnswers.contains(Probe.answerText(to: question)))
        }
        #expect(!journal.contains { $0.kind == .divergence })
    }

    // MARK: - The counter

    @Test("a tool loop of three calls: the counter is the size of the render, not the sum of the calls")
    func toolLoopCounterIsTheRenderNotTheSum() async throws {
        let fixture = try await Self.makeProbe(toolRoundsPerTurn: Self.toolLoopRounds)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collect(fixture.session.streamEvents(to: Self.firstQuestion))

        let calls = events.compactMap { event -> GenerationCallUsage? in
            guard case .generationCall(let usage) = event else { return nil }
            return usage
        }
        #expect(calls.count == Self.toolLoopRounds + 1)
        let render = try Self.contextAfterAnswer(of: fixture, to: Self.firstQuestion)
        let sum = calls.map(\.contextTokens).reduce(0, +)
        #expect(render < sum)
        let counter = await Self.counterTokens(of: fixture.session, contextTokens: Self.probeContextTokens)
        #expect(counter == render)
        #expect(counter == calls.last?.contextTokens)
        let turnEnded = try #require(
            events.compactMap { event -> TokenUsage? in
                guard case .turnEnded(let usage) = event else { return nil }
                return usage
            }.last)
        #expect(turnEnded.contextFill == Double(render) / Double(Self.probeContextTokens))
    }

    @Test("the counter goes up, restarts at a compaction from the instructions and the snapshot, and goes up again")
    func counterRestartsAtEachCompaction() async throws {
        let fixture = try await Self.makeProbe(toolRoundsPerTurn: 1)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let session = fixture.session
        let contextTokens = Self.probeContextTokens

        _ = try await session.respond(to: Self.firstQuestion)
        let afterFirst = await Self.counterTokens(of: session, contextTokens: contextTokens)
        #expect(afterFirst == (try Self.contextAfterAnswer(of: fixture, to: Self.firstQuestion)))
        _ = try await session.respond(to: Self.secondQuestion)
        let afterSecond = await Self.counterTokens(of: session, contextTokens: contextTokens)
        #expect(afterSecond == (try Self.contextAfterAnswer(of: fixture, to: Self.secondQuestion)))
        #expect(afterSecond > afterFirst)

        try await Self.compact(session)
        let afterCompaction = await Self.counterTokens(of: session, contextTokens: contextTokens)
        let snapshot = await session.transcript
        #expect(afterCompaction < afterSecond)
        #expect(afterCompaction == (try Self.counter.count(snapshot)))
        #expect(Self.texts(of: snapshot).first == Self.instructions)

        _ = try await session.respond(to: Self.thirdQuestion)
        let afterThird = await Self.counterTokens(of: session, contextTokens: contextTokens)
        #expect(afterThird == (try Self.contextAfterAnswer(of: fixture, to: Self.thirdQuestion)))
        #expect(afterThird > afterCompaction)
        let render = Self.texts(of: try Self.newestRender(of: fixture))
        #expect(render.first == Self.instructions)
        #expect(!render.joined().contains(Self.firstQuestion))
        #expect(!render.joined().contains(Self.secondQuestion))
    }

    @Test("a ceiling stop with the counter under the trigger does not compact, although the sum of the calls is over it")
    func ceilingStopUnderTheTriggerDoesNotCompactOnTheSum() async throws {
        let calls = Self.ceilingStopCalls
        let budget = Self.ceilingStopBudget
        let sum = calls.map { $0.tokensIn + $0.tokensOut }.reduce(0, +)
        let last = try #require(calls.last)
        #expect(sum >= budget.triggerTokens)
        #expect(last.tokensIn + last.tokensOut < budget.triggerTokens)
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: Self.meteredContextTokens, budget: budget, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collect(fixture.session.streamEvents(to: Self.firstQuestion, maxTokens: Self.ceiling))

        #expect(events.compactionResults.isEmpty)
        let finishReasons = events.compactMap { event -> FinishReason? in
            guard case .turnEnded(let usage) = event else { return nil }
            return usage.finishReason
        }
        #expect(finishReasons == [.maxTokens])
        let counter = await Self.counterTokens(of: fixture.session, contextTokens: Self.meteredContextTokens)
        #expect(counter == last.tokensIn + last.tokensOut)
    }
}
