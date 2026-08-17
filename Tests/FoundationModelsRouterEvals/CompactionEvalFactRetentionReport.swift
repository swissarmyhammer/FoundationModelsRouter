import Foundation

@testable import FoundationModelsRouter

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

    /// How many round trips to the model the fold's summarizer made. One fold
    /// makes more than one call when ``Summarization`` chunks a long span into
    /// several map calls plus a reduce call, so this distinguishes a
    /// single-shot fold from a chunked one.
    let summarizerCallCount: Int

    /// Whether this sample's compaction reached the model-assisted
    /// ``Summarization`` stage — the one stage that leaves a summary a later
    /// question can be answered from.
    var folded: Bool {
        stagesApplied.contains(Summarization.stageName)
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
        let seedsByQuestion = Dictionary(seeds.map { ($0.question, $0) }, uniquingKeysWith: { first, _ in first })
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

    /// Renders the classified samples as the per-sample table a run's
    /// attribution is read from — one stanza per sample, then the counts.
    ///
    /// - Parameter findings: The classified samples to render, in sample order.
    /// - Returns: The table's lines, ready to print one per line.
    static func lines(of findings: [CompactionEvalFactRetentionFinding]) -> [String] {
        let tallied = counts(of: findings)
        let tally = CompactionEvalFactRetentionClass.allCases.map { classification in
            "\(classification.rawValue)=\(tallied[classification] ?? 0)"
        }
        return ["FactRetention per-sample evidence — \(findings.count) samples"]
            + findings.flatMap(stanza(for:))
            + ["counts: " + tally.joined(separator: " ")]
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
            )
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
            classification: .unrecognizedSample
        )
    }

    /// Renders one classified sample's stanza.
    ///
    /// - Parameter finding: The classified sample to render.
    /// - Returns: The stanza's lines — the verdict line, then each text the
    ///   verdict was read from, one per line so a multi-line summary stays
    ///   legible.
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
        ]
    }

    /// Renders a sample's summary for the table: the text itself, or a marker
    /// naming what the fold stored instead.
    ///
    /// - Parameter diagnostic: The sample's recorded evidence.
    /// - Returns: The summary text, ``absentSummaryMarker`` when the fold
    ///   produced none, or ``emptySummaryMarker`` when it stored text holding
    ///   no characters.
    private static func renderedSummary(of diagnostic: CompactionEvalSampleDiagnostic) -> String {
        guard let summary = diagnostic.summary else { return absentSummaryMarker }
        return carriesText(summary) ? summary : emptySummaryMarker
    }
}
