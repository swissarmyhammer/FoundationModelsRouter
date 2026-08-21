import Foundation
import FoundationModels
import FoundationModelsRouter

/// The summarizer the fast compaction suites hand ``Compactor``: one blank-slate
/// session per call over a resident model, and a record of every call made.
///
/// The blank slate matters for the same reason it does in production
/// (`RoutedSessionActorCompaction.swift`'s own summarizer): a fold's summarizer
/// call must not be added to an already-full transcript, must not write the
/// fold's own prompt into the real history, and must not leak one chunk into
/// the next.
///
/// The record is what lets a suite assert the summarizer ran at all, which is
/// one of the facts these suites exist to prove. It keeps the generation ceiling
/// of each call rather than a bare count, so the count and the ceiling the fold
/// arithmetic produced are one measurement rather than two.
public actor CountingBlankSlateSummarizer: CompactionSummarizer {
    /// The resident model each call opens its own session over.
    private let container: MLXFoundationModelsContainer

    /// One completed summarizer call.
    ///
    /// `Sendable` is declared rather than inferred: a public struct gets no
    /// implicit conformance, and ``CompactionFold/run(_:summarization:container:label:)``
    /// reads ``CountingBlankSlateSummarizer/calls`` across the actor boundary.
    public struct Call: Sendable {
        /// The generation ceiling ``Summarization`` computed for this call.
        public let ceiling: Int

        /// The text the model answered with, unchanged.
        public let answer: String
    }

    /// Every call made, in call order — so `calls.count` is the number of
    /// generations this fold cost.
    ///
    /// The ANSWER is kept beside the ceiling, and not only the ceiling, because
    /// a fold that gets discarded returns no summary at all: the size the model
    /// really wrote is then readable nowhere else. That size is the one number
    /// that separates "the summarizer misbehaved" from "the guard is wrong",
    /// and `^azd033m` needed it.
    public private(set) var calls: [Call] = []

    /// Creates a summarizer over `container`.
    ///
    /// - Parameter container: The resident model to generate with.
    package init(container: MLXFoundationModelsContainer) {
        self.container = container
    }

    /// Condenses `prompt` in one generation over a session that has seen
    /// nothing else.
    ///
    /// - Parameters:
    ///   - prompt: The assembled compaction instructions and content.
    ///   - maxTokens: The generation ceiling ``Summarization`` computed.
    /// - Returns: The model's answer, unchanged.
    /// - Throws: Whatever the backend throws.
    public func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let answer = try await container.makeSession(transcript: Transcript(entries: []))
            .respond(to: prompt, maxTokens: maxTokens)
        calls.append(Call(ceiling: maxTokens, answer: answer))
        return answer
    }
}

/// What one folded run produced — everything the fast compaction suites read,
/// measured once so no suite has to restate the wiring.
///
/// `Sendable` is declared rather than inferred, for the reason
/// ``CountingBlankSlateSummarizer/Call`` declares it: a public struct gets no
/// implicit conformance, and a suite reads this value back across an `await`.
public struct CompactionFoldOutcome: Sendable {
    /// The transcript that was folded.
    public let transcript: Transcript

    /// The stage the fold ran with.
    public let summarization: Summarization

    /// What ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``
    /// reported.
    public let result: CompactionResult

    /// Every summarizer call the fold made, in call order.
    public let calls: [CountingBlankSlateSummarizer.Call]

    /// The generation ceiling of each call, in call order.
    public var ceilings: [Int] { calls.map(\.ceiling) }

    /// The estimated size of each call's ANSWER, before the cut, in call order.
    public var answerTokens: [Int] { calls.map { Compactor.estimatedTokenCount(of: $0.answer) } }

    /// The estimated size of the span the fold replaced, in the tokens
    /// ``Compactor``'s did-not-shrink guard measures.
    public var spanTokens: Int {
        CompactionFold.foldedSpanTokens(
            of: transcript, keepRecentTurns: summarization.keepRecentTurns)
    }
}

/// The one way a fast compaction suite folds a transcript it already holds
/// against a model it has already loaded.
///
/// Two suites wrote this same body before this type — ``CompactionSmokeIntegrationTests``
/// over a transcript built in Swift, and ``RecordedTranscriptCompactionIntegrationTests``
/// over a transcript read back from a recording — and they differ only in where
/// the transcript came from. This type is the same consolidation
/// ``RealModelContainer`` and ``RealModelHarness`` are, and for the same reason.
///
/// It deliberately loads nothing and evicts nothing. A caller owns the model's
/// lifetime, because a caller is the only thing that knows whether it is going
/// to fold once or twice.
public enum CompactionFold {
    /// The scale ``budget(forcingSummarizationOf:)`` states its fold target
    /// against.
    ///
    /// ``TokenBudget`` takes its target as a FRACTION of a limit, and a caller
    /// here needs a target at a particular token COUNT read off the transcript.
    /// A large limit makes the fraction resolve back to that count exactly
    /// rather than to a rounding of it. Nothing else reads this limit:
    /// ``Compactor`` compares against ``TokenBudget/targetTokens`` alone.
    private static let budgetLimit = 1_000_000

    /// Where the fold target sits, as a share of what the deterministic stages
    /// can reach on their own.
    ///
    /// The target has one job: be low enough that ``ToolOutputElision`` and
    /// ``TurnTruncation`` cannot land the transcript under it, so the pipeline
    /// falls through to ``Summarization``. Half of the floor those two reach is
    /// unreachable by construction, whatever the transcript grows or shrinks to
    /// — which is why the target is derived from the transcript rather than
    /// written down beside it.
    private static let foldTargetShareOfDeterministicFloor = 0.5

    /// The budget that forces `transcript` all the way through the
    /// model-assisted stage.
    ///
    /// Derived from the transcript rather than written down, so a transcript
    /// that changes size carries its own budget with it.
    ///
    /// - Parameter transcript: The transcript the budget is measured against.
    /// - Returns: The budget to fold with.
    public static func budget(forcingSummarizationOf transcript: Transcript) -> TokenBudget {
        let deterministicFloor = Compactor.estimatedTokenCount(
            of: TurnTruncation().apply(ToolOutputElision().apply(transcript)))
        let targetTokens = Int(Double(deterministicFloor) * foldTargetShareOfDeterministicFloor)
        return TokenBudget(limit: budgetLimit, target: Double(targetTokens) / Double(budgetLimit))
    }

    /// The estimated token count of the span `transcript`'s fold replaces — the
    /// turns outside the recency window, partitioned exactly as
    /// ``Summarization`` partitions them.
    ///
    /// - Parameters:
    ///   - transcript: The transcript about to be folded.
    ///   - keepRecentTurns: The recency window the fold leaves untouched.
    /// - Returns: The folded span's size, in the estimated tokens
    ///   ``Compactor``'s did-not-shrink guard measures.
    public static func foldedSpanTokens(of transcript: Transcript, keepRecentTurns: Int) -> Int {
        let (_, turns) = TranscriptTurns.split(Array(transcript))
        let (old, _) = TranscriptTurns.partition(turns, keepRecentTurns: keepRecentTurns)
        return Compactor.estimatedTokenCount(of: Transcript(entries: old.flatMap(\.entries)))
    }

    /// Folds `transcript` once against `container`, and puts the run's own
    /// numbers on the record before any assertion reads them — so a red run
    /// states what it went red on rather than only which assertion failed.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to fold.
    ///   - summarization: The model-assisted stage to fold with.
    ///   - container: The resident model every summarizer call generates over.
    ///   - label: The tag every printed line of this run carries, so a suite
    ///     that folds twice can tell its two runs apart in the output.
    /// - Returns: Everything the run measured.
    /// - Throws: Whatever the fold throws.
    // Only the suites in the IntegrationTests package call this.
    // Periphery reads only this package's index, thus it finds no caller.
    // periphery:ignore
    package static func run(
        _ transcript: Transcript,
        summarization: Summarization,
        container: MLXFoundationModelsContainer,
        label: String
    ) async throws -> CompactionFoldOutcome {
        let summarizer = CountingBlankSlateSummarizer(container: container)
        let (_, result) = try await Compactor.compact(
            transcript,
            budget: budget(forcingSummarizationOf: transcript),
            summarizer: summarizer,
            summarization: summarization
        )
        let outcome = CompactionFoldOutcome(
            transcript: transcript,
            summarization: summarization,
            result: result,
            calls: await summarizer.calls
        )
        print(
            "[\(label)] summarizerCalls=\(outcome.ceilings.count) ceilings=\(outcome.ceilings) "
                + "answerTokens=\(outcome.answerTokens) "
                + "spanTokens=\(outcome.spanTokens) "
                + "summaryTokens=\(Compactor.estimatedTokenCount(of: result.summary ?? "")) "
                + "tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) "
                + "stages=\(result.stagesApplied)"
        )
        return outcome
    }
}
