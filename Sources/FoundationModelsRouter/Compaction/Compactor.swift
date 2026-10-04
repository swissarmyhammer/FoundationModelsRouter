import Foundation
import Logging
import FoundationModels

/// What one compaction did: the size of the live context before and after, the
/// stage that ran, and the summary text.
public struct CompactionResult: Sendable, Equatable {
    /// This compaction's own identity, a generated ``ULID`` string.
    public let id: String

    /// The summary the compaction wrote, or `nil` when no summary applies.
    public let summary: String?

    /// The summary entry's `Transcript.Entry.id`, or `nil`. Present exactly
    /// when ``summary`` is.
    public let summaryEntryId: String?

    /// The ``ModelRef`` string of the model that wrote ``summary``, or `nil`.
    public let summarizerModel: String?

    /// The summarizer tier that wrote ``summary``, or `nil` when no summary
    /// applies. A result rebuilt from a checkpoint does not know its tier and
    /// holds `nil`.
    public let summarizerTier: CompactionSummarizerTier?

    /// The size of the live context, in tokens, before the compaction ran.
    public let tokensBefore: Int

    /// The size of the live context, in tokens, after the compaction ran.
    public let tokensAfter: Int

    /// The stages that were applied, in order. It holds
    /// ``Summarization/stageName`` when a summary applies, and nothing when the
    /// compaction left the live context as it was.
    public let stagesApplied: [String]

    /// The size, in tokens, of the protected tool outputs and of the calls that
    /// made them. The new snapshot keeps them word for word (see
    /// ``ToolOutputProtection``). `0` when the session has no rule, or when the
    /// rule protects nothing.
    ///
    /// Protected outputs count against the target: the summary gets the room
    /// that the target leaves after them.
    public let protectedTokens: Int

    /// Why the compaction left the live context as it was, or `nil` when a
    /// summary applies or when the live context was already under its target.
    public let shortfall: CompactionShortfall?

    /// The target the retry after a context overflow computed for this
    /// compaction, or `nil` for every other compaction. It states what the
    /// retry aimed for and why. Its ``OverflowRetryTarget/rule`` states which
    /// rule chose the target: the caller's response ceiling, or the configured
    /// target of the budget.
    public let overflowRetryTarget: OverflowRetryTarget?

    /// Creates a compaction result.
    ///
    /// - Parameters:
    ///   - id: This compaction's identity. Defaults to a freshly generated ``ULID`` string.
    ///   - summary: The summary the compaction wrote, or `nil`.
    ///   - summaryEntryId: The summary entry's `Transcript.Entry.id`, or `nil`. Defaults to `nil`.
    ///   - summarizerModel: The ``ModelRef`` string of the summary's writer, or `nil`. Defaults to `nil`.
    ///   - summarizerTier: The tier that wrote the summary, or `nil`. Defaults to `nil`.
    ///   - tokensBefore: The size before the compaction, in tokens.
    ///   - tokensAfter: The size after the compaction, in tokens.
    ///   - stagesApplied: The stages that ran, in order.
    ///   - protectedTokens: The size of the protected tool outputs and their
    ///     calls. Defaults to `0`.
    ///   - shortfall: Why the compaction left the live context as it was, or
    ///     `nil`. Defaults to `nil`.
    ///   - overflowRetryTarget: The target the retry after a context overflow
    ///     computed, or `nil`. Defaults to `nil`.
    public init(
        id: String = ULID.generate().description,
        summary: String?,
        summaryEntryId: String? = nil,
        summarizerModel: String? = nil,
        summarizerTier: CompactionSummarizerTier? = nil,
        tokensBefore: Int,
        tokensAfter: Int,
        stagesApplied: [String],
        protectedTokens: Int = 0,
        shortfall: CompactionShortfall? = nil,
        overflowRetryTarget: OverflowRetryTarget? = nil
    ) {
        self.id = id
        self.summary = summary
        self.summaryEntryId = summaryEntryId
        self.summarizerModel = summarizerModel
        self.summarizerTier = summarizerTier
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.stagesApplied = stagesApplied
        self.protectedTokens = protectedTokens
        self.shortfall = shortfall
        self.overflowRetryTarget = overflowRetryTarget
    }

    /// Returns a copy of this result that carries the target the retry after
    /// a context overflow computed for it. Every other field is copied
    /// unchanged.
    ///
    /// - Parameter target: The target the retry computed.
    /// - Returns: The copy that carries `target`.
    func withOverflowRetryTarget(_ target: OverflowRetryTarget) -> CompactionResult {
        copy(id: id, overflowRetryTarget: target)
    }

    /// Returns a copy of this result with the identity `id`. Every other
    /// field is copied unchanged. The session gives an automatic compaction
    /// its id before the compaction runs, so that
    /// ``SessionEvent/compactionStarted(_:)`` and the result carry the same id.
    ///
    /// - Parameter id: The identity of the compaction.
    /// - Returns: The copy that carries `id`.
    func withId(_ id: String) -> CompactionResult {
        copy(id: id, overflowRetryTarget: overflowRetryTarget)
    }

    /// Returns a copy of this result with `id` and `overflowRetryTarget`.
    private func copy(id: String, overflowRetryTarget target: OverflowRetryTarget?) -> CompactionResult {
        CompactionResult(
            id: id,
            summary: summary,
            summaryEntryId: summaryEntryId,
            summarizerModel: summarizerModel,
            summarizerTier: summarizerTier,
            tokensBefore: tokensBefore,
            tokensAfter: tokensAfter,
            stagesApplied: stagesApplied,
            protectedTokens: protectedTokens,
            shortfall: shortfall,
            overflowRetryTarget: target
        )
    }
}

/// Why a compaction left the live context as it was.
public enum CompactionShortfall: Sendable, Equatable {
    /// The target leaves no room for a summary. The instructions, the
    /// protected tool outputs and the pending-runs rendering alone fill the
    /// target. The compaction did not call a summarizer.
    ///
    /// - Parameter allowedSummaryTokens: The room the target leaves for the
    ///   summary, in tokens. It is zero or less.
    case targetLeavesNoRoomForSummary(allowedSummaryTokens: Int)

    /// No summarizer window holds the input of the call. The live context is
    /// at the window. The compaction did not call a summarizer.
    ///
    /// - Parameters:
    ///   - inputTokens: The size of the call's input, in tokens.
    ///   - windowTokens: The largest window of the summarizers offered, in tokens.
    case inputFillsSummarizerWindow(inputTokens: Int, windowTokens: Int)

    /// The summarizer answered, but the new snapshot was not smaller than the
    /// live context it replaces. The compaction discarded the summary.
    ///
    /// - Parameter snapshotTokens: The size of the discarded snapshot, in tokens.
    case summaryDidNotShrinkContext(snapshotTokens: Int)
}

/// The summarizer tier that writes a compaction's summary.
public enum CompactionSummarizerTier: String, Sendable, Equatable {
    /// The profile's ``LanguageModelProfile/flash`` slot.
    case flash

    /// The session's own model.
    case ownModel = "own-model"
}

/// One model a compaction can summarize with, and the window it runs in.
package struct CompactionSummarizerSlot: Sendable {
    /// The tier this slot fills.
    let tier: CompactionSummarizerTier

    /// The model the call goes to.
    let summarizer: any CompactionSummarizer

    /// The model's context window, in tokens. The call's input and its output
    /// share it.
    let windowTokens: Int

    /// The ``ModelRef`` string of the model, or `nil` when the caller does not
    /// name it. It is written to ``CompactionResult/summarizerModel``.
    let model: String?

    /// Creates a summarizer slot.
    ///
    /// - Parameters:
    ///   - tier: The tier this slot fills.
    ///   - summarizer: The model the call goes to.
    ///   - windowTokens: The model's context window, in tokens.
    ///   - model: The ``ModelRef`` string of the model, or `nil`.
    package init(
        tier: CompactionSummarizerTier, summarizer: any CompactionSummarizer, windowTokens: Int, model: String?
    ) {
        self.tier = tier
        self.summarizer = summarizer
        self.windowTokens = windowTokens
        self.model = model
    }
}


/// The compaction: one summarizer call over the whole live context.
///
/// The call's input is the compaction prompt and the whole live context, the
/// instructions included. The summary restarts the live context as a new
/// snapshot: the instructions, the summary entry with its checkpoint, the
/// protected tool outputs, and the pending-runs rendering. The recorded
/// transcript keeps the whole history.
///
/// Every size before a call is counted by the ``TokenCounter`` the caller
/// passes: the session's own, backed by the tokenizer of its model.
package enum Compactor {
    /// Compacts `transcript` in one summarizer call.
    ///
    /// The live context is left as it is when it is already under the budget's
    /// target, or when the compaction reports a ``CompactionShortfall``.
    ///
    /// `summarizers` holds the tiers in the order of preference. A tier runs
    /// when its window holds the call (see
    /// ``CompactionCall/outputCeiling(for:)``). When a tier throws and another
    /// tier can still run, `abandoning` gets the error, and the next tier runs
    /// when `abandoning` returns. When the last tier throws, `abandoning` gets
    /// the error, and the error reaches the caller when `abandoning` returns.
    ///
    /// - Parameters:
    ///   - transcript: The live context to compact.
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against.
    ///   - counter: The counter every size is measured with.
    ///   - summarizers: The summarizer tiers, in the order of preference.
    ///   - pendingRuns: The run-plane summaries of the runs still running, in tracking order.
    ///   - protection: The host rule whose protected tool outputs the new
    ///     snapshot keeps word for word, or `nil` (the default) to protect nothing.
    ///   - explicitLogger: The explicit logger of the session that compacts,
    ///     or `nil` (the default) for a logger of the module. The record of a
    ///     ``CompactionShortfall`` goes to it (``log(_:to:)``). A session pump
    ///     is a detached task, so only an explicit logger takes the record to
    ///     the logger that the caller gave the session.
    ///   - abandoning: Gets each summarizer failure with the tier that raised
    ///     it. It throws to stop the compaction. The default returns.
    /// - Returns: The new live context and a report of what happened.
    /// - Throws: What the last tier throws, what `abandoning` throws, what
    ///   `counter` throws, or ``SummarizationError/emptySummary`` when the
    ///   summary holds no text.
    package static func compact(
        _ transcript: Transcript,
        prompt: CompactionPrompt = .default,
        budget: TokenBudget,
        counter: any TokenCounter,
        summarizers: [CompactionSummarizerSlot],
        pendingRuns: [CompactionSegment.PendingRunSummary] = [],
        protection: ToolOutputProtection? = nil,
        explicitLogger: Logger? = nil,
        abandoning: @Sendable (any Error, CompactionSummarizerTier) async throws -> Void = { _, _ in }
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        let compacted = try await planAndSummarize(
            transcript, prompt: prompt, budget: budget, counter: counter, summarizers: summarizers,
            pendingRuns: pendingRuns, protection: protection, abandoning: abandoning)
        if let shortfall = compacted.result.shortfall {
            log(shortfall, to: RouterTelemetry.logger(.compaction, explicit: explicitLogger))
        }
        return compacted
    }

    /// Plans the compaction of `transcript` and runs its summarizer call. See
    /// ``compact(_:prompt:budget:counter:summarizers:pendingRuns:protection:explicitLogger:abandoning:)``,
    /// which logs the shortfall of the result.
    ///
    /// - Parameters:
    ///   - transcript: The live context to compact.
    ///   - prompt: The compaction prompt sent to the summarizer.
    ///   - budget: The token budget to compact against.
    ///   - counter: The counter every size is measured with.
    ///   - summarizers: The summarizer tiers, in the order of preference.
    ///   - pendingRuns: The run-plane summaries of the runs still running, in tracking order.
    ///   - protection: The host rule whose protected tool outputs the new
    ///     snapshot keeps word for word, or `nil` to protect nothing.
    ///   - abandoning: Gets each summarizer failure with the tier that raised
    ///     it. It throws to stop the compaction.
    /// - Returns: The new live context and a report of what happened.
    /// - Throws: What the last tier throws, what `abandoning` throws, what
    ///   `counter` throws, or ``SummarizationError/emptySummary`` when the
    ///   summary holds no text.
    private static func planAndSummarize(
        _ transcript: Transcript,
        prompt: CompactionPrompt,
        budget: TokenBudget,
        counter: any TokenCounter,
        summarizers: [CompactionSummarizerSlot],
        pendingRuns: [CompactionSegment.PendingRunSummary],
        protection: ToolOutputProtection?,
        abandoning: @Sendable (any Error, CompactionSummarizerTier) async throws -> Void
    ) async throws -> (transcript: Transcript, result: CompactionResult) {
        let plan = try Summarization().plan(
            transcript, prompt: prompt, budget: budget, counter: counter, pendingRuns: pendingRuns,
            protection: protection)
        let call: CompactionCall
        switch plan {
        case .finished(let result):
            return (transcript, result)
        case .summarize(let planned):
            call = planned
        }

        let runnable = summarizers.compactMap { slot in call.outputCeiling(for: slot).map { (slot, $0) } }
        guard let last = runnable.last else {
            let windowTokens = summarizers.map(\.windowTokens).max() ?? 0
            return (
                transcript,
                call.shortfallResult(.inputFillsSummarizerWindow(inputTokens: call.inputTokens, windowTokens: windowTokens))
            )
        }
        for (slot, ceiling) in runnable.dropLast() {
            do {
                return try await call.summarize(with: slot, outputCeiling: ceiling, counter: counter)
            } catch {
                try await abandoning(error, slot.tier)
            }
        }
        do {
            return try await call.summarize(with: last.0, outputCeiling: last.1, counter: counter)
        } catch {
            try await abandoning(error, last.0.tier)
            throw error
        }
    }

    /// The constant message of the log record of a ``CompactionShortfall``.
    static let shortfallLogMessage = "a compaction left the live context as it was"

    /// Logs why a compaction left the live context as it was. The message is
    /// constant, and the values are metadata (``logMetadata(of:)``). The call
    /// is synchronous and adds no suspension point.
    ///
    /// - Parameters:
    ///   - shortfall: The reason.
    ///   - logger: The logger of the record.
    private static func log(_ shortfall: CompactionShortfall, to logger: Logger) {
        logger.warning("\(shortfallLogMessage)", metadata: logMetadata(of: shortfall))
    }

    /// The log metadata of a shortfall: the name of its case and its token
    /// counts.
    ///
    /// - Parameter shortfall: The reason a compaction left the context as it
    ///   was.
    /// - Returns: The case name under ``RouterTelemetry/LogMetadataKey/shortfall``
    ///   and each token count under its own key.
    private static func logMetadata(of shortfall: CompactionShortfall) -> Logger.Metadata {
        switch shortfall {
        case .targetLeavesNoRoomForSummary(let allowedSummaryTokens):
            [
                RouterTelemetry.LogMetadataKey.shortfall: "targetLeavesNoRoomForSummary",
                RouterTelemetry.LogMetadataKey.allowedSummaryTokens: "\(allowedSummaryTokens)",
            ]
        case .inputFillsSummarizerWindow(let inputTokens, let windowTokens):
            [
                RouterTelemetry.LogMetadataKey.shortfall: "inputFillsSummarizerWindow",
                RouterTelemetry.LogMetadataKey.inputTokens: "\(inputTokens)",
                RouterTelemetry.LogMetadataKey.windowTokens: "\(windowTokens)",
            ]
        case .summaryDidNotShrinkContext(let snapshotTokens):
            [
                RouterTelemetry.LogMetadataKey.shortfall: "summaryDidNotShrinkContext",
                RouterTelemetry.LogMetadataKey.snapshotTokens: "\(snapshotTokens)",
            ]
        }
    }
}
