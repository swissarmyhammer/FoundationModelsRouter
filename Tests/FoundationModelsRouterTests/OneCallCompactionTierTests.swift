import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises how ``Compactor`` picks the summarizer of its one call from the
/// windows it is offered, the output ceiling of that call, and what happens
/// when a tier fails.
///
/// Every size is counted by ``characterTokenCounter``, one token per
/// `Character`. A test first learns the size of the call's input from a probe
/// compaction over a window with no bound. The prompt does not change with
/// the window, so the probe input is the input of every later call.
@Suite("One-call compaction: summarizer choice, output ceiling and fallback")
struct OneCallCompactionTierTests {
    /// One summarizer failure that a compaction gave to its `abandoning`
    /// closure.
    private struct Abandoned: Equatable {
        /// The failure, or `nil` when it is not a ``FailingSummarizer/Failure``.
        let failure: FailingSummarizer.Failure?

        /// The tier that raised it.
        let tier: CompactionSummarizerTier
    }

    /// Records every failure a compaction gives to `abandoning`, in order.
    private actor AbandonLog {
        /// The failures, in order.
        private(set) var abandoned: [Abandoned] = []

        /// Records one failure.
        ///
        /// - Parameters:
        ///   - error: The failure.
        ///   - tier: The tier that raised it.
        func record(_ error: any Error, tier: CompactionSummarizerTier) {
            abandoned.append(Abandoned(failure: error as? FailingSummarizer.Failure, tier: tier))
        }
    }

    /// The live context and the budget every test here compacts: a small
    /// instructions entry and one long turn, with the default target.
    ///
    /// - Returns: The live context and its budget.
    private static func sizedContext() -> (transcript: Transcript, budget: TokenBudget) {
        let transcript = Transcript(entries: [
            SizedEntries.instructions(id: "instructions", tokens: 10),
            SizedEntries.prompt(id: "prompt", tokens: 400),
            SizedEntries.response(id: "response", tokens: 400),
        ])
        return (transcript, summarizingCompactionBudget(for: Array(transcript)))
    }

    /// The size, in tokens, of the input the compaction of `transcript` sends,
    /// and the summary size it allows. Both are read from a probe compaction
    /// over a window with no bound.
    ///
    /// - Parameters:
    ///   - transcript: The live context.
    ///   - budget: The token budget.
    /// - Returns: The input size and the allowed summary size, in tokens.
    /// - Throws: What the probe compaction throws.
    private static func probe(
        _ transcript: Transcript, budget: TokenBudget
    ) async throws -> (inputTokens: Int, allowedTokens: Int) {
        let summarizer = RecordingSummarizer(summary: "probe")
        _ = try await compactWithUnboundedWindow(transcript, budget: budget, summarizer: summarizer)
        let prompt = try #require(await summarizer.prompts.first)
        let instructions = Array(transcript).filter {
            if case .instructions = $0 { return true }
            return false
        }
        return (prompt.count, budget.targetTokens - characterCount(of: instructions))
    }

    /// Compacts `transcript` with the character counter and `slots`.
    ///
    /// - Parameters:
    ///   - transcript: The live context.
    ///   - budget: The token budget.
    ///   - slots: The summarizer tiers, in the order of preference.
    ///   - log: The log `abandoning` records into.
    /// - Returns: The new live context and the result.
    /// - Throws: What the compaction throws.
    private static func compact(
        _ transcript: Transcript, budget: TokenBudget, slots: [CompactionSummarizerSlot], log: AbandonLog = AbandonLog()
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        try await Compactor.compact(
            transcript, budget: budget, counter: characterTokenCounter, summarizers: slots,
            abandoning: { error, tier in await log.record(error, tier: tier) })
    }

    /// A flash slot and an own-model slot, each over its own summarizer.
    ///
    /// - Parameters:
    ///   - flash: The flash summarizer.
    ///   - flashWindow: The flash window, in tokens.
    ///   - own: The own-model summarizer.
    ///   - ownWindow: The own-model window, in tokens.
    /// - Returns: The slots, flash first.
    private static func slots(
        flash: any CompactionSummarizer, flashWindow: Int, own: any CompactionSummarizer, ownWindow: Int
    ) -> [CompactionSummarizerSlot] {
        [
            CompactionSummarizerSlot(tier: .flash, summarizer: flash, windowTokens: flashWindow, model: "org/flash"),
            CompactionSummarizerSlot(tier: .ownModel, summarizer: own, windowTokens: ownWindow, model: "org/own"),
        ]
    }

    @Test("flash writes the summary when its window holds the input and the stated size")
    func flashRunsWhenItsWindowHoldsInputAndSize() async throws {
        let (transcript, budget) = Self.sizedContext()
        let (inputTokens, allowedTokens) = try await Self.probe(transcript, budget: budget)
        let flash = RecordingSummarizer(summary: "flash summary")
        let own = RecordingSummarizer(summary: "own summary")

        let (_, result) = try await Self.compact(
            transcript, budget: budget,
            slots: Self.slots(flash: flash, flashWindow: inputTokens + allowedTokens, own: own, ownWindow: .max))

        #expect(result.summarizerTier == .flash)
        #expect(result.summarizerModel == "org/flash")
        #expect(result.summary == "flash summary")
        #expect(await flash.maxTokens == [allowedTokens])
        #expect(await own.prompts.isEmpty)
    }

    @Test("the own model writes the summary when the flash window is too small for the input and the stated size")
    func ownModelRunsWhenFlashWindowIsTooSmall() async throws {
        let (transcript, budget) = Self.sizedContext()
        let (inputTokens, allowedTokens) = try await Self.probe(transcript, budget: budget)
        let flash = RecordingSummarizer(summary: "flash summary")
        let own = RecordingSummarizer(summary: "own summary")

        let (_, result) = try await Self.compact(
            transcript, budget: budget,
            slots: Self.slots(flash: flash, flashWindow: inputTokens + allowedTokens - 1, own: own, ownWindow: .max))

        #expect(result.summarizerTier == .ownModel)
        #expect(result.summarizerModel == "org/own")
        #expect(await flash.prompts.isEmpty)
        #expect(await own.prompts.count == 1)
    }

    @Test("the call's output ceiling is the room the window leaves after the input")
    func ceilingIsWindowLessInput() async throws {
        let (transcript, budget) = Self.sizedContext()
        let (inputTokens, _) = try await Self.probe(transcript, budget: budget)
        let room = 1
        let own = RecordingSummarizer(summary: "own summary")

        _ = try await Self.compact(
            transcript, budget: budget,
            slots: [CompactionSummarizerSlot(tier: .ownModel, summarizer: own, windowTokens: inputTokens + room, model: nil)])

        #expect(await own.maxTokens == [room])
    }

    @Test("no window leaves room after the input: no call, the live context stays, the shortfall names the input and the largest window")
    func noWindowLeavesRoom() async throws {
        let (transcript, budget) = Self.sizedContext()
        let (inputTokens, allowedTokens) = try await Self.probe(transcript, budget: budget)
        let flash = RecordingSummarizer(summary: "flash summary")
        let own = RecordingSummarizer(summary: "own summary")
        let flashWindow = inputTokens + allowedTokens - 1

        let (compacted, result) = try await Self.compact(
            transcript, budget: budget, slots: Self.slots(flash: flash, flashWindow: flashWindow, own: own, ownWindow: inputTokens))

        #expect(result.shortfall == .inputFillsSummarizerWindow(inputTokens: inputTokens, windowTokens: flashWindow))
        #expect(compacted == transcript)
        #expect(result.stagesApplied.isEmpty)
        #expect(result.summarizerTier == nil)
        #expect(await flash.prompts.isEmpty)
        #expect(await own.prompts.isEmpty)
    }

    @Test("a flash failure goes to abandoning with the flash tier, and the own model then writes the summary")
    func flashFailureFallsBackToOwnModel() async throws {
        let (transcript, budget) = Self.sizedContext()
        let flash = FailingSummarizer(name: "flash")
        let own = RecordingSummarizer(summary: "own summary")
        let log = AbandonLog()

        let (_, result) = try await Self.compact(
            transcript, budget: budget, slots: Self.slots(flash: flash, flashWindow: .max, own: own, ownWindow: .max),
            log: log)

        #expect(await log.abandoned == [Abandoned(failure: FailingSummarizer.Failure(name: "flash"), tier: .flash)])
        #expect(result.summarizerTier == .ownModel)
        #expect(result.summary == "own summary")
    }

    @Test("a failure of the last tier goes to abandoning, then reaches the caller")
    func lastTierFailureIsAbandonedThenThrown() async throws {
        let (transcript, budget) = Self.sizedContext()
        let log = AbandonLog()
        let slots = Self.slots(
            flash: FailingSummarizer(name: "flash"), flashWindow: .max, own: FailingSummarizer(name: "own"),
            ownWindow: .max)

        await #expect(throws: FailingSummarizer.Failure(name: "own")) {
            _ = try await Self.compact(transcript, budget: budget, slots: slots, log: log)
        }
        #expect(
            await log.abandoned == [
                Abandoned(failure: FailingSummarizer.Failure(name: "flash"), tier: .flash),
                Abandoned(failure: FailingSummarizer.Failure(name: "own"), tier: .ownModel),
            ])
    }

    @Test("acceptance: a 100,000-token context with 4,000 tokens of instructions compacts in one own-model call that states 46,000 tokens")
    func acceptanceCaseRunsOneOwnModelCall() async throws {
        let contextTokens = 100_000
        let instructionsTokens = 4_000
        let conversationTokens = 48_000
        let flashWindow = 32_768
        let ownWindow = 131_072
        let transcript = Transcript(entries: [
            SizedEntries.instructions(id: "instructions", tokens: instructionsTokens),
            SizedEntries.prompt(id: "prompt", tokens: conversationTokens),
            SizedEntries.response(id: "response", tokens: conversationTokens),
        ])
        #expect(characterCount(of: Array(transcript)) == contextTokens)
        let flash = RecordingSummarizer(summary: "flash summary")
        let own = RecordingSummarizer(summary: "own summary")

        let (_, result) = try await Self.compact(
            transcript, budget: TokenBudget(limit: contextTokens),
            slots: Self.slots(flash: flash, flashWindow: flashWindow, own: own, ownWindow: ownWindow))

        #expect(result.summarizerTier == .ownModel)
        #expect(await flash.prompts.isEmpty)
        let prompts = await own.prompts
        #expect(prompts.count == 1)
        let prompt = try #require(prompts.first)
        #expect(prompt.contains("about 46000 tokens"))
        #expect(await own.maxTokens == [ownWindow - prompt.count])
    }
}
