import Foundation
import FoundationModels

/// A ``PersistableStructuredSegment`` that records one compaction's fold
/// metadata. It travels as a `Transcript.StructuredSegment` under the schema
/// name `FoundationModelsRouter.CompactionSegment`.
package struct CompactionSegment: PersistableStructuredSegment, Equatable, CustomStringConvertible, Sendable {
    /// One background run's summary (token, op, latest progress) carried
    /// across the compaction boundary. Never a run's output.
    package struct PendingRunSummary: Codable, Equatable, Sendable {
        /// The run's completion token.
        let completionToken: String

        /// The canonical `"verb noun"` op string of the background operation.
        let op: String

        /// The latest progress detail reported for the run, or `nil`.
        let latestProgressDetail: String?

        /// Creates one background run's summary.
        init(completionToken: String, op: String, latestProgressDetail: String?) {
            self.completionToken = completionToken
            self.op = op
            self.latestProgressDetail = latestProgressDetail
        }
    }

    /// The fold metadata one compaction's ``CompactionSegment`` carries.
    package struct Content: Codable, Equatable, Sendable {
        /// The ordered entry ids of the compacted live window, including the
        /// summary entry.
        var liveWindowEntryIds: [String]

        /// The entry ids this fold replaced. The entries stay in the
        /// recorded transcript.
        var foldedEntryIds: [String]

        /// The measured transcript size, in tokens, before this fold.
        var tokensBefore: Int

        /// The measured transcript size, in tokens, after this fold.
        var tokensAfter: Int

        /// The pipeline stages this fold applied, in order.
        var stagesApplied: [String]

        /// The name of the `CompactionPrompt` that produced this fold's summary.
        var promptName: String

        /// The summaries of the runs still running when this boundary was
        /// written, in tracking order, or `nil` when there were none.
        var pendingRuns: [PendingRunSummary]?

        /// Creates fold metadata. `pendingRuns` defaults to `nil`.
        init(
            liveWindowEntryIds: [String],
            foldedEntryIds: [String],
            tokensBefore: Int,
            tokensAfter: Int,
            stagesApplied: [String],
            promptName: String,
            pendingRuns: [PendingRunSummary]? = nil
        ) {
            self.liveWindowEntryIds = liveWindowEntryIds
            self.foldedEntryIds = foldedEntryIds
            self.tokensBefore = tokensBefore
            self.tokensAfter = tokensAfter
            self.stagesApplied = stagesApplied
            self.promptName = promptName
            self.pendingRuns = pendingRuns
        }
    }

    /// The unique identifier of this segment.
    package let id: String

    /// The fold metadata this segment carries.
    package let content: Content

    /// Creates a segment that wraps `content`. `id` defaults to a fresh UUID.
    package init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }

    /// The flat description persisted with this segment's JSON content.
    package var description: String {
        let pendingRunsSuffix = content.pendingRuns.map { "; pending runs: \($0.count)" } ?? ""
        return "Compaction: \(content.foldedEntryIds.count) entries folded into a "
            + "\(content.liveWindowEntryIds.count)-entry window "
            + "(\(content.tokensBefore) -> \(content.tokensAfter) tokens; "
            + "stages: \(content.stagesApplied.joined(separator: ", ")); "
            + "prompt: \(content.promptName)\(pendingRunsSuffix))"
    }

    /// Renders `pendingRuns` as the model-visible pending-run text of a
    /// compaction boundary: one line per run with token, op, and latest
    /// progress. Never a run's output.
    internal static func renderedPendingRuns(_ pendingRuns: [PendingRunSummary]) -> String {
        let lines = pendingRuns.map { run in
            let progress = run.latestProgressDetail.map { " — latest progress: \($0)" } ?? " — no progress reported yet"
            return "- completionToken \(run.completionToken): \(run.op)\(progress)"
        }
        return """
            Background runs still pending across this compaction. \
            The session reports each run when it settles. \
            For an earlier look, call status(), or wait()/cancel() with a completion token:
            \(lines.joined(separator: "\n"))
            """
    }

    /// Builds the boundary entry an applied fold appends: a `.response` with
    /// a text segment for `summaryText` (id `<entryId>-text`), a pending-runs
    /// text segment (id `<entryId>-pending-runs`) when `content.pendingRuns`
    /// is not `nil`, and the `.structure` ``CompactionSegment`` manifest.
    ///
    /// - Parameters:
    ///   - entryId: The boundary entry's `Transcript.Entry.id`.
    ///   - summaryText: The model-visible summary text, or empty.
    ///   - content: The fold manifest the `.structure` segment wraps.
    /// - Returns: The boundary entry.
    internal static func boundaryEntry(
        id entryId: String,
        summaryText: String,
        content: Content
    ) -> Transcript.Entry {
        var segments: [Transcript.Segment] = [
            .text(Transcript.TextSegment(id: "\(entryId)-text", content: summaryText))
        ]
        // A session with no background runs adds nothing; one with background runs
        // carries their rendering as an additional text segment — the only
        // segment kind the model-facing transcript rendering reads — so a
        // post-compaction model keeps its tokens until each run is reported.
        if let pendingRuns = content.pendingRuns {
            segments.append(
                .text(
                    Transcript.TextSegment(
                        id: "\(entryId)-pending-runs",
                        content: renderedPendingRuns(pendingRuns)
                    )
                )
            )
        }
        segments.append(CompactionSegment(content: content).transcriptSegment)
        return .response(
            Transcript.Response(id: entryId, segments: segments)
        )
    }

    /// The ``Content/promptName`` of a deterministic-only fold: empty,
    /// because no summarizer read a prompt.
    internal static let deterministicFoldPromptName = ""

    /// Returns `folded` with one boundary entry appended. The boundary has an
    /// empty summary and ``deterministicFoldPromptName``.
    ///
    /// - Parameters:
    ///   - folded: The transcript the deterministic pipeline produced.
    ///   - preFoldEntryIds: The entry ids before the fold; the ones absent from `folded` become ``Content/foldedEntryIds``.
    ///   - tokensBefore: The pre-fold transcript size.
    ///   - tokensAfter: The post-fold transcript size, on the same scale as `tokensBefore`.
    ///   - stagesApplied: The pipeline stages the fold applied, in order.
    ///   - pendingRuns: The summaries of the runs still running, or `nil`.
    /// - Returns: `folded` plus the boundary entry, in that order.
    internal static func appendingDeterministicBoundary(
        to folded: Transcript,
        preFoldEntryIds: [String],
        tokensBefore: Int,
        tokensAfter: Int,
        stagesApplied: [String],
        pendingRuns: [PendingRunSummary]?
    ) -> Transcript {
        let entryId = "compaction-boundary-\(UUID().uuidString)"
        let liveEntryIds = folded.map(\.id)
        let liveIdSet = Set(liveEntryIds)
        let boundary = boundaryEntry(
            id: entryId,
            // Empty deliberately: a deterministic fold synthesizes no summary
            // text, and the boundary's job for the model is only to exist —
            // "a boundary entry whose text part is empty or minimal".
            summaryText: "",
            content: Content(
                liveWindowEntryIds: liveEntryIds + [entryId],
                foldedEntryIds: preFoldEntryIds.filter { !liveIdSet.contains($0) },
                tokensBefore: tokensBefore,
                tokensAfter: tokensAfter,
                stagesApplied: stagesApplied,
                promptName: deterministicFoldPromptName,
                pendingRuns: pendingRuns
            )
        )
        return Transcript(entries: Array(folded) + [boundary])
    }
}
