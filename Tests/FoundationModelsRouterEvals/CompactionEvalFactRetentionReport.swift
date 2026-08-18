import Foundation

@testable import FoundationModelsRouter

/// What one summarizer call of a fold asked the model for, and what it
/// answered.
///
/// Recorded because a discarded fold leaves no other trace of its summary.
/// `Compactor.compact` throws such a fold away and reports the shortfall exit's
/// `nil` summary, so the size of the summary that lost — the one number that
/// says whether the fold missed by a few percent or by a multiple — survives
/// nowhere else. The summarizer holds it at the moment it answers, so it is
/// kept there.
struct CompactionEvalSummarizerCall: Sendable {
    /// The ceiling, in tokens, the fold gave this call.
    ///
    /// ``Summarization``'s summary allowance plus its
    /// ``Summarization/reasoningTokenHeadroom``, and it bounds the WHOLE
    /// generation — the reasoning and the answer together — rather than the
    /// summary text alone. Recorded beside the answer so a run can read the two
    /// against each other.
    let maxTokens: Int

    /// The model's complete answer to this call.
    let answer: String
}

/// One gated sample's raw `FactRetention` evidence, recorded by
/// ``CompactionEvalRealSubjectRunner`` as each sample runs.
///
/// ``CompactionEvaluationOutcome`` carries the produced answer but not the
/// fold's summary text, so a failing `FactRetention` sample cannot be
/// attributed from it: a fact the fold dropped and a fact the fold preserved
/// into an answer that ignored it look identical there. This record keeps both
/// sides of that question — the summary the fold synthesized and the answer
/// the resumed session gave — so ``CompactionEvalFactRetentionClass`` can tell
/// them apart for every sample rather than for a hand-picked few.
struct CompactionEvalSampleDiagnostic: Sendable {
    /// The question asked of the resumed, post-compaction session — the join
    /// key back to the sample's ``CompactionEvalSeed``, which
    /// `CompactionEvalFactRetentionReportTests` pins as unique across seeds.
    let question: String

    /// The fold's synthesized summary text (``CompactionResult/summary``), or
    /// `nil` when no `Summarization` stage ran and so no summary exists.
    let summary: String?

    /// The resumed session's answer to ``question`` — the exact string
    /// `FactRetention` checks for the seed's key phrase.
    let answer: String

    /// The compaction stages that actually ran
    /// (``CompactionResult/stagesApplied``).
    let stagesApplied: [String]

    /// Every summarizer call the fold made, in call order — what each asked the
    /// model for and what the model answered.
    ///
    /// The whole list rather than a count, because a discarded fold's summary
    /// text survives nowhere else — see ``CompactionEvalSummarizerCall``.
    let summarizerCalls: [CompactionEvalSummarizerCall]

    /// How many round trips to the model the fold's summarizer made. One fold
    /// makes more than one call when ``Summarization`` chunks a long span into
    /// several map calls plus a reduce call, so this distinguishes a
    /// single-shot fold from a chunked one.
    var summarizerCallCount: Int {
        summarizerCalls.count
    }

    /// Whether this sample's compaction reached the model-assisted
    /// ``Summarization`` stage — the one stage that leaves a summary a later
    /// question can be answered from.
    var folded: Bool {
        stagesApplied.contains(Summarization.stageName)
    }

    /// Whether this sample's fold ran and was then thrown away.
    ///
    /// `Compactor.compact` refuses a fold whose summary left the transcript no
    /// smaller than it was, and its shortfall exit reports the same values as a
    /// fold that never ran at all: no summary, and no stage applied. The two are
    /// not the same measurement, and telling them apart is what this reads.
    ///
    /// The summarizer is called from ``Summarization`` and nowhere else, and an
    /// applied `Summarization` always names itself in
    /// ``CompactionResult/stagesApplied``. So a call with no stage to show for it
    /// is a fold that ran and was discarded, and nothing else can produce that
    /// pair.
    var foldDiscarded: Bool {
        summarizerCallCount > 0 && !folded
    }

    /// The call whose answer a discarded fold would have stored, or `nil` when
    /// this sample's fold was not discarded.
    ///
    /// The LAST call, because that is the summary a fold stores: a span inside
    /// ``Summarization/maxChunkTokens`` takes one call, and a longer one takes
    /// several map calls and then reduce rounds whose final call produces the
    /// single summary the boundary carries.
    var discardedSummary: CompactionEvalSummarizerCall? {
        guard foldDiscarded else { return nil }
        return summarizerCalls.last
    }
}

/// Which of the mutually exclusive outcomes one gated `FactRetention` sample
/// landed in.
///
/// The point of the split is attribution. `FactRetention` scores one bit per
/// sample — the answer either contained the seed's key phrase or it did not —
/// which says nothing about *where* a failing sample lost the fact. These
/// cases name the distinguishable places, so a run's failures can be
/// attributed as a body rather than argued from a handful of examples.
enum CompactionEvalFactRetentionClass: String, Sendable, CaseIterable {
    /// The answer contained the key phrase: `FactRetention` passed. Decided by
    /// the same test the metric itself applies, so this case's count always
    /// agrees with the metric's mean.
    case retained

    /// The summary carried the key phrase verbatim and the answer still did
    /// not — the fold preserved the fact and the *answering* turn lost it.
    case answerMissedFactSummaryCarriedIt

    /// A summary exists but does not carry the key phrase — the fold itself
    /// dropped the fact.
    case summaryLostFact

    /// The fold produced no summary at all, so the resumed session was never
    /// given anything to answer from.
    ///
    /// Covers a missing summary and an empty one alike. The gated run of
    /// 2026-08-17 recorded `Optional("")` on 19 of 19 seeds — the fold ran, the
    /// summarizer answered, and the answer held no characters — and a `nil`
    /// test alone filed every one of them under ``summaryLostFact``, which
    /// reads as a summary that forgot the fact. A summary with no text carries
    /// nothing to forget, so it belongs here.
    ///
    /// Covers a discarded fold too, and for the same reason: `Compactor.compact`
    /// throws a fold away when its summary left the transcript no smaller, and
    /// the resumed session is then handed the original turns with no summary in
    /// them. What separates the two is legible in the table rather than here —
    /// see ``CompactionEvalFactRetentionReport/discardedSummaryMarker``.
    case foldProducedNoSummary

    /// The recorded sample's question matched no seed, so its key phrase is
    /// unknown and it cannot be classified. Present so every recorded sample
    /// lands in exactly one case and the counts always sum to the sample
    /// total.
    case unrecognizedSample

    /// Classifies one sample from the two texts that decide it.
    ///
    /// - Parameters:
    ///   - summary: The fold's synthesized summary, or `nil` when the fold
    ///     produced none.
    ///   - answer: The resumed session's answer.
    ///   - factKeyPhrase: The seed's short, distinctive key phrase — the same
    ///     value `FactRetention` checks the answer for.
    /// - Returns: The case this sample landed in, never ``unrecognizedSample``
    ///   (which only ``CompactionEvalFactRetentionReport`` assigns, to a sample
    ///   with no matching seed).
    static func classify(summary: String?, answer: String, factKeyPhrase: String) -> Self {
        // Deliberately the same test `CompactionEvaluation`'s own
        // `FactRetention` evaluator applies, so this case's count and the
        // metric's mean can never disagree.
        if answer.localizedCaseInsensitiveContains(factKeyPhrase) { return .retained }
        // A summary with no text is a fold that produced none, whether it
        // arrived as `nil` or as `""` — see `foldProducedNoSummary`.
        guard let summary, CompactionEvalFactRetentionReport.carriesText(summary) else {
            return .foldProducedNoSummary
        }
        return summary.localizedCaseInsensitiveContains(factKeyPhrase)
            ? .answerMissedFactSummaryCarriedIt
            : .summaryLostFact
    }
}

/// One classified sample: the seed's ground truth, the evidence the gated run
/// recorded, and the case the two together land in.
struct CompactionEvalFactRetentionFinding: Sendable {
    /// The seed this sample ran (``CompactionEvalSeed/id``), or
    /// ``CompactionEvalFactRetentionReport/unmatchedSeedID`` when no seed
    /// matched.
    let seedID: String

    /// The fact planted in the seed's foldable head.
    let plantedFact: String

    /// The short key phrase `FactRetention` checks for.
    let factKeyPhrase: String

    /// Whether ``factKeyPhrase`` appears verbatim in the fold's summary — the
    /// measurement that separates a compaction defect from an answering one.
    let factInSummary: Bool

    /// The evidence recorded while the sample ran.
    let diagnostic: CompactionEvalSampleDiagnostic

    /// The case this sample landed in.
    let classification: CompactionEvalFactRetentionClass

    /// The span this sample's fold was to replace, in the estimated tokens
    /// `Compactor` measures a transcript in — `0` when the sample matched no
    /// seed, since no span is then known.
    ///
    /// The other half of a discarded fold's measurement. `Compactor.compact`
    /// keeps a fold only when it leaves the transcript smaller, so a summary
    /// that lost is only legible beside the span it was meant to replace.
    let foldableSpanEstimatedTokens: Int
}

/// Turns the gated run's recorded per-sample evidence into a classified table
/// and its per-case counts.
///
/// Kept as functions over plain values — rather than folded into
/// ``CompactionEvalRealSubjectRunner`` — so the classification the gated run's
/// attribution rests on is itself covered by hermetic tests that need no
/// model.
enum CompactionEvalFactRetentionReport {
    /// The ``CompactionEvalFactRetentionFinding/seedID`` stamped on a recorded
    /// sample whose question matched no seed.
    static let unmatchedSeedID = "<unmatched>"

    /// What ``stanza(for:)`` renders in place of a fold that produced no
    /// summary at all.
    static let absentSummaryMarker = "<none>"

    /// What ``stanza(for:)`` renders in place of a summary that holds no text.
    ///
    /// The printer wrote the text itself, so an empty summary rendered as
    /// `summary=` with nothing after it — which reads as a truncated line
    /// rather than as the measurement it is. A marker states it.
    static let emptySummaryMarker = "<empty>"

    /// What ``stanza(for:)`` renders in place of a fold that ran and was then
    /// discarded — see ``CompactionEvalSampleDiagnostic/foldDiscarded``.
    ///
    /// `Compactor.compact` reports a discarded fold through the same shortfall
    /// exit an unfolded transcript takes, so the summary arrives as `nil` and the
    /// table wrote ``absentSummaryMarker`` for it — the same rendering a stage
    /// that never ran gets. A fold the summarizer really answered, and the
    /// pipeline then threw away, is a different measurement and says so.
    static let discardedSummaryMarker = "<discarded>"

    /// What ``lines(of:expecting:)`` renders in place of the unreached seed ids
    /// when the run reached every seed of its tier.
    ///
    /// Stated rather than left out. A table that printed the unreached line only
    /// when it had names to print would leave a reader unable to tell a complete
    /// run from a printer that never states one.
    static let everySeedReachedMarker = "<none>"

    /// How many characters of a discarded fold's summary ``stanza(for:)``
    /// prints before it cuts the text off.
    ///
    /// A discarded summary is bounded only by the ceiling the whole generation
    /// ran under — ``Summarization/reasoningTokenHeadroom`` on top of the
    /// summary allowance — so it can run to tens of thousands of characters,
    /// and a table that printed one whole for every sample would bury the rest
    /// of the run's evidence. `1000` is nearly twice the largest summary the
    /// allowance itself buys (``Summarization/minimumSummaryTokens`` at
    /// ``Compactor/charsPerTokenEstimate`` is 512 characters), so a summary
    /// that stayed inside its allowance prints whole, and one that did not is
    /// visibly cut with its real size stated on the line above.
    static let discardedSummaryPrefixCharacters = 1000

    /// What ``stanza(for:)`` appends to a discarded summary it cut short at
    /// ``discardedSummaryPrefixCharacters``.
    ///
    /// Stated rather than left to the reader to infer from the byte count on
    /// the line above: a printed summary that simply stopped mid-sentence reads
    /// as a model that stopped mid-sentence, which is a different defect.
    static let discardedSummaryTruncationMarker = "<cut>"

    /// Whether `summary` holds any text at all.
    ///
    /// The one place this question is answered, so the classification and the
    /// rendered table can never disagree about which summaries are empty.
    ///
    /// - Parameter summary: The summary text to read.
    /// - Returns: `true` when the text holds at least one character that is
    ///   not whitespace.
    static func carriesText(_ summary: String) -> Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Classifies every recorded sample against its seed.
    ///
    /// - Parameters:
    ///   - diagnostics: The evidence recorded by the gated run, in sample
    ///     order.
    ///   - seeds: The seeds the run drew its samples from, joined by
    ///     ``CompactionEvalSeed/question``.
    /// - Returns: One finding per recorded sample, in the same order. A sample
    ///   whose question matches no seed still yields a finding, classified
    ///   ``CompactionEvalFactRetentionClass/unrecognizedSample``, so no
    ///   recorded sample is silently dropped from the table.
    static func findings(
        for diagnostics: [CompactionEvalSampleDiagnostic],
        seeds: [CompactionEvalSeed]
    ) -> [CompactionEvalFactRetentionFinding] {
        let seedsByQuestion = CompactionEvalSeed.keyedByQuestion(seeds)
        return diagnostics.map { diagnostic in
            guard let seed = seedsByQuestion[diagnostic.question] else {
                return unrecognizedFinding(for: diagnostic)
            }
            return finding(for: diagnostic, seed: seed)
        }
    }

    /// Counts the findings in each case.
    ///
    /// - Parameter findings: The classified samples to count.
    /// - Returns: A count for every case of
    ///   ``CompactionEvalFactRetentionClass``, including the ones no finding
    ///   landed in, so a zero is stated rather than missing.
    static func counts(
        of findings: [CompactionEvalFactRetentionFinding]
    ) -> [CompactionEvalFactRetentionClass: Int] {
        var counts = Dictionary(uniqueKeysWithValues: CompactionEvalFactRetentionClass.allCases.map { ($0, 0) })
        for finding in findings {
            counts[finding.classification, default: 0] += 1
        }
        return counts
    }

    /// The ids of the seeds `findings` covers none of — the seeds the run never
    /// reached.
    ///
    /// A gated run ends on its suite time limit as readily as on its own
    /// assertion, and it records evidence only for the samples that ran. The
    /// seeds it never got to leave nothing behind at all, so the difference
    /// against the tier's own seed set is the only place they are visible.
    ///
    /// - Parameters:
    ///   - findings: The classified samples the run recorded.
    ///   - seeds: The seeds the tier was to measure, in the order it states
    ///     them.
    /// - Returns: The ids of the seeds no finding names, in `seeds` order.
    static func unreachedSeedIDs(
        in findings: [CompactionEvalFactRetentionFinding],
        expecting seeds: [CompactionEvalSeed]
    ) -> [String] {
        let reached = Set(findings.map(\.seedID))
        return seeds.map(\.id).filter { !reached.contains($0) }
    }

    /// Renders the classified samples as the per-sample table a run's
    /// attribution is read from — one stanza per sample, then the counts, then
    /// the seeds the run never reached.
    ///
    /// - Parameters:
    ///   - findings: The classified samples to render, in sample order.
    ///   - seeds: The seeds the tier was to measure. The head and the closing
    ///     line are read against this, so a run cut short states what it never
    ///     got to rather than reading as a whole measurement of a smaller tier.
    /// - Returns: The table's lines, ready to print one per line.
    static func lines(
        of findings: [CompactionEvalFactRetentionFinding],
        expecting seeds: [CompactionEvalSeed]
    ) -> [String] {
        let tallied = counts(of: findings)
        let tally = CompactionEvalFactRetentionClass.allCases.map { classification in
            "\(classification.rawValue)=\(tallied[classification] ?? 0)"
        }
        return ["FactRetention per-sample evidence — \(findings.count) of \(seeds.count) seeds measured"]
            + findings.flatMap(stanza(for:))
            + ["counts: " + tally.joined(separator: " ")]
            + [unreachedLine(of: findings, expecting: seeds)]
    }

    /// Renders the closing line naming the seeds the run never reached.
    ///
    /// - Parameters:
    ///   - findings: The classified samples the run recorded.
    ///   - seeds: The seeds the tier was to measure.
    /// - Returns: The line, naming each unreached seed, or stating
    ///   ``everySeedReachedMarker`` when the run reached them all.
    private static func unreachedLine(
        of findings: [CompactionEvalFactRetentionFinding],
        expecting seeds: [CompactionEvalSeed]
    ) -> String {
        let unreached = unreachedSeedIDs(in: findings, expecting: seeds)
        guard !unreached.isEmpty else {
            return "unreached: \(everySeedReachedMarker) — every one of the \(seeds.count) seeds ran"
        }
        return "unreached: \(unreached.count) of \(seeds.count) seeds never ran — "
            + unreached.joined(separator: " ")
    }

    /// Builds the finding for a recorded sample that matched a seed.
    ///
    /// - Parameters:
    ///   - diagnostic: The sample's recorded evidence.
    ///   - seed: The seed the sample ran.
    /// - Returns: The classified finding.
    private static func finding(
        for diagnostic: CompactionEvalSampleDiagnostic,
        seed: CompactionEvalSeed
    ) -> CompactionEvalFactRetentionFinding {
        CompactionEvalFactRetentionFinding(
            seedID: seed.id,
            plantedFact: seed.plantedFact,
            factKeyPhrase: seed.factKeyPhrase,
            factInSummary: diagnostic.summary?.localizedCaseInsensitiveContains(seed.factKeyPhrase) ?? false,
            diagnostic: diagnostic,
            classification: CompactionEvalFactRetentionClass.classify(
                summary: diagnostic.summary,
                answer: diagnostic.answer,
                factKeyPhrase: seed.factKeyPhrase
            ),
            foldableSpanEstimatedTokens: seed.foldableSpanEstimatedTokens
        )
    }

    /// Builds the finding for a recorded sample whose question matched no seed.
    ///
    /// - Parameter diagnostic: The unmatched sample's recorded evidence.
    /// - Returns: A finding carrying empty ground truth and classified
    ///   ``CompactionEvalFactRetentionClass/unrecognizedSample``.
    private static func unrecognizedFinding(
        for diagnostic: CompactionEvalSampleDiagnostic
    ) -> CompactionEvalFactRetentionFinding {
        CompactionEvalFactRetentionFinding(
            seedID: unmatchedSeedID,
            plantedFact: "",
            factKeyPhrase: "",
            factInSummary: false,
            diagnostic: diagnostic,
            classification: .unrecognizedSample,
            foldableSpanEstimatedTokens: 0
        )
    }

    /// Renders one classified sample's stanza.
    ///
    /// - Parameter finding: The classified sample to render.
    /// - Returns: The stanza's lines — the verdict line, then each text the
    ///   verdict was read from, one per line so a multi-line summary stays
    ///   legible, then the measurement of a discarded fold when there is one.
    private static func stanza(for finding: CompactionEvalFactRetentionFinding) -> [String] {
        [
            "- seed=\(finding.seedID) class=\(finding.classification.rawValue)"
                + " factInSummary=\(finding.factInSummary)"
                + " folded=\(finding.diagnostic.folded)"
                + " summarizerCalls=\(finding.diagnostic.summarizerCallCount)"
                + " stages=\(finding.diagnostic.stagesApplied.joined(separator: ","))",
            "  fact=\(finding.plantedFact)",
            "  key=\(finding.factKeyPhrase)",
            "  question=\(finding.diagnostic.question)",
            "  answer=\(finding.diagnostic.answer)",
            "  summary=\(renderedSummary(of: finding.diagnostic))",
        ] + discardedLines(for: finding)
    }

    /// Renders the lines a discarded fold adds to its stanza, or none at all
    /// for a sample whose fold was applied or never ran.
    ///
    /// ``discardedSummaryMarker`` alone says a fold ran and was thrown away, and
    /// not by how much. These lines say by how much: the size of the summary
    /// that lost, the span it was to replace, and the ceiling the call that
    /// wrote it ran under — the three numbers `Compactor.compact`'s
    /// did-not-shrink guard is decided by — and then the text itself, bounded.
    ///
    /// - Parameter finding: The classified sample to render.
    /// - Returns: The two lines, or an empty array.
    private static func discardedLines(for finding: CompactionEvalFactRetentionFinding) -> [String] {
        guard let discarded = finding.diagnostic.discardedSummary else { return [] }
        return [
            "  discarded=\(discarded.answer.utf8.count) bytes"
                + " summaryTokens=\(Summarization.estimatedTokens(of: discarded.answer))"
                + " spanTokens=\(finding.foldableSpanEstimatedTokens)"
                + " ceiling=\(discarded.maxTokens)",
            "  discardedText=\(boundedText(of: discarded.answer))",
        ]
    }

    /// `text`, cut to ``discardedSummaryPrefixCharacters`` and marked with
    /// ``discardedSummaryTruncationMarker`` when it is longer than that.
    ///
    /// - Parameter text: The text to bound.
    /// - Returns: The whole text, or its bounded prefix plus the marker.
    private static func boundedText(of text: String) -> String {
        guard text.count > discardedSummaryPrefixCharacters else { return text }
        return String(text.prefix(discardedSummaryPrefixCharacters)) + discardedSummaryTruncationMarker
    }

    /// Renders a sample's summary for the table: the text itself, or a marker
    /// naming what the fold stored instead.
    ///
    /// - Parameter diagnostic: The sample's recorded evidence.
    /// - Returns: The summary text, ``discardedSummaryMarker`` when the fold ran
    ///   and was thrown away, ``absentSummaryMarker`` when no fold produced one
    ///   at all, or ``emptySummaryMarker`` when it stored text holding no
    ///   characters.
    private static func renderedSummary(of diagnostic: CompactionEvalSampleDiagnostic) -> String {
        guard let summary = diagnostic.summary else {
            // Read before the absent case, because a discarded fold reports the
            // same `nil` summary an unfolded transcript does.
            return diagnostic.foldDiscarded ? discardedSummaryMarker : absentSummaryMarker
        }
        return carriesText(summary) ? summary : emptySummaryMarker
    }
}
