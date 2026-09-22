import Foundation
import FoundationModels
import FoundationModelsRouter

/// The summarizer the fast compaction suites hand ``Compactor``: one blank-slate
/// session per call over a resident model, and a record of every call made.
///
/// The blank slate matters for the same reason it does in production
/// (`RoutedSessionActorCompaction.swift`'s own summarizer): a compaction's summarizer
/// call must not be added to an already-full transcript, and must not write the
/// compaction's own prompt into the real history.
///
/// The record is what lets a suite assert the summarizer ran at all, which is
/// one of the facts these suites exist to prove. It keeps the generation ceiling
/// of each call rather than a bare count, so the count and the ceiling the
/// compaction computed are one measurement rather than two.
public actor CountingBlankSlateSummarizer: CompactionSummarizer {
    /// The loaded real model each call opens its own session over, with the
    /// decoding strategy the suite pinned.
    private let loaded: RealModelContainer

    /// One completed summarizer call.
    ///
    /// `Sendable` is declared rather than inferred: a public struct gets no
    /// implicit conformance, and ``TranscriptCompaction/run(_:container:windowTokens:label:)``
    /// reads ``CountingBlankSlateSummarizer/calls`` across the actor boundary.
    public struct Call: Sendable {
        /// The generation ceiling the compaction computed for this call.
        public let ceiling: Int

        /// The text the model answered with, unchanged.
        public let answer: String
    }

    /// Every call made, in call order — so `calls.count` is the number of
    /// generations this compaction cost.
    ///
    /// The ANSWER is kept beside the ceiling, and not only the ceiling, because
    /// a compaction that gets discarded returns no summary at all: the size the model
    /// really wrote is then readable nowhere else. That size is the one number
    /// that separates "the summarizer misbehaved" from "the check is wrong",
    /// and `^azd033m` needed it.
    public private(set) var calls: [Call] = []

    /// Creates a summarizer over `container`.
    ///
    /// - Parameter container: The loaded real model to generate with, and the
    ///   decoding strategy the suite pinned. The container stores no mode, so
    ///   each call passes ``RealModelContainer/samplingMode``.
    package init(container: RealModelContainer) {
        self.loaded = container
    }

    /// Answers `prompt` in one generation over a session that has seen
    /// nothing else.
    ///
    /// - Parameters:
    ///   - prompt: The assembled compaction prompt and the live context.
    ///   - maxTokens: The generation ceiling the compaction computed.
    /// - Returns: The model's answer, unchanged.
    /// - Throws: Whatever the backend throws.
    public func summarize(_ prompt: String, maxTokens: Int) async throws -> String {
        let answer = try await loaded.container
            .makeSession(transcript: Transcript(entries: []), samplingMode: loaded.samplingMode)
            .respond(to: prompt, maxTokens: maxTokens)
        calls.append(Call(ceiling: maxTokens, answer: answer))
        return answer
    }
}

/// What one compacted run produced — everything the fast compaction suites read,
/// measured once so no suite has to restate the wiring.
///
/// `Sendable` is declared rather than inferred, for the reason
/// ``CountingBlankSlateSummarizer/Call`` declares it: a public struct gets no
/// implicit conformance, and a suite reads this value back across an `await`.
public struct TranscriptCompactionOutcome: Sendable {
    /// The transcript that was compacted.
    public let transcript: Transcript

    /// What ``Compactor/compact(_:prompt:budget:counter:summarizers:summarization:pendingRuns:protection:abandoning:)``
    /// reported.
    public let result: CompactionResult

    /// Every summarizer call the compaction made, in call order.
    public let calls: [CountingBlankSlateSummarizer.Call]

    /// The generation ceiling of each call, in call order.
    public var ceilings: [Int] { calls.map(\.ceiling) }

    /// The size of each call's answer, in call order, in the tokens `counter`
    /// counts.
    ///
    /// - Parameter counter: The counter the answers are measured with. A
    ///   suite passes the loaded container's own counter, the counter the
    ///   compaction itself counted with, so every size it reads is in one unit.
    /// - Returns: One size per call, in call order.
    public func answerTokens(counter: any TokenCounter) -> [Int] {
        calls.map { counter.count($0.answer) }
    }

    /// The size of the span the compaction replaced, in the tokens the
    /// compaction's did-not-shrink check measures: every entry but the
    /// instructions.
    ///
    /// - Parameter counter: The counter the span is measured with. A suite
    ///   passes the loaded container's own counter, the counter the
    ///   compaction itself counted with.
    /// - Returns: The span's size.
    /// - Throws: What `counter` throws.
    public func spanTokens(counter: any TokenCounter) throws -> Int {
        let span = transcript.filter {
            if case .instructions = $0 { return false }
            return true
        }
        return try counter.count(Transcript(entries: span))
    }
}

/// The one way a fast compaction suite compacts a transcript it already holds
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
/// to compact once or twice.
public enum TranscriptCompaction {
    /// The budget a run compacts `transcript` against: a limit of the
    /// transcript's own size, at ``TokenBudget``'s default target.
    ///
    /// Derived from the transcript rather than written down, so a transcript
    /// that changes size carries its own budget with it. The transcript is
    /// then over the target, so the compaction makes its one summarizer call.
    ///
    /// - Parameters:
    ///   - transcript: The transcript the budget is measured against.
    ///   - counter: The counter the transcript is measured with, the counter
    ///     the compaction itself counts with.
    /// - Returns: The budget to compact with.
    /// - Throws: What `counter` throws.
    public static func budget(of transcript: Transcript, counter: any TokenCounter) throws -> TokenBudget {
        TokenBudget(limit: try counter.count(transcript))
    }

    /// Compacts `transcript` once against `container`, and puts the run's own
    /// numbers on the record before any assertion reads them — so a red run
    /// states what it went red on rather than only which assertion failed.
    ///
    /// Every size the run counts, the budget it derives and the sizes it
    /// prints, is counted with `container`'s own counter: the counter of the
    /// loaded model's tokenizer, the counter the compaction counts with.
    ///
    /// - Parameters:
    ///   - transcript: The transcript to compact.
    ///   - container: The loaded real model the summarizer call generates
    ///     over, with the decoding strategy the suite pinned, and the counter
    ///     every size is measured with.
    ///   - windowTokens: The context window `container` was loaded at. The
    ///     call's input and its output share it.
    ///   - label: The tag every printed line of this run carries, so a suite
    ///     that compacts twice can tell its two runs apart in the output.
    /// - Returns: Everything the run measured.
    /// - Throws: Whatever the compaction throws, or what the container's
    ///   counter throws.
    // Only the suites in the IntegrationTests package call this.
    // Periphery reads only this package's index, thus it finds no caller.
    // periphery:ignore
    package static func run(
        _ transcript: Transcript,
        container: RealModelContainer,
        windowTokens: Int,
        label: String
    ) async throws -> TranscriptCompactionOutcome {
        let counter = container.container.tokenCounter
        let summarizer = CountingBlankSlateSummarizer(container: container)
        let (_, result) = try await Compactor.compact(
            transcript,
            budget: try Self.budget(of: transcript, counter: counter),
            counter: counter,
            summarizers: [
                CompactionSummarizerSlot(
                    tier: .ownModel, summarizer: summarizer, windowTokens: windowTokens, model: nil)
            ]
        )
        let outcome = TranscriptCompactionOutcome(
            transcript: transcript,
            result: result,
            calls: await summarizer.calls
        )
        let spanTokens = try outcome.spanTokens(counter: counter)
        let answerTokens = outcome.answerTokens(counter: counter)
        let summaryTokens = counter.count(result.summary ?? "")
        print(
            "[\(label)] summarizerCalls=\(outcome.ceilings.count) ceilings=\(outcome.ceilings) "
                + "answerTokens=\(answerTokens) spanTokens=\(spanTokens) summaryTokens=\(summaryTokens) "
                + "tokensBefore=\(result.tokensBefore) tokensAfter=\(result.tokensAfter) "
                + "stages=\(result.stagesApplied) shortfall=\(String(describing: result.shortfall))"
        )
        return outcome
    }
}
