import Foundation
import FoundationModels

/// A ``PersistableStructuredSegment`` that records one compaction's
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

    /// The compaction metadata one compaction's ``CompactionSegment`` carries.
    package struct Content: Codable, Equatable, Sendable {
        /// The ordered entry ids of the compacted live window, including the
        /// summary entry.
        var liveWindowEntryIds: [String]

        /// The entry ids this compaction replaced. The entries stay in the
        /// recorded transcript.
        var compactedEntryIds: [String]

        /// The measured transcript size, in tokens, before this compaction.
        var tokensBefore: Int

        /// The measured transcript size, in tokens, after this compaction.
        var tokensAfter: Int

        /// The stages this compaction applied, in order. A checkpoint recorded
        /// before compaction became one call can name more than one stage.
        var stagesApplied: [String]

        /// The name of the `CompactionPrompt` that produced this compaction's summary.
        var promptName: String

        /// The summaries of the runs still running when this boundary was
        /// written, in tracking order, or `nil` when there were none.
        var pendingRuns: [PendingRunSummary]?

        /// Creates compaction metadata. `pendingRuns` defaults to `nil`.
        init(
            liveWindowEntryIds: [String],
            compactedEntryIds: [String],
            tokensBefore: Int,
            tokensAfter: Int,
            stagesApplied: [String],
            promptName: String,
            pendingRuns: [PendingRunSummary]? = nil
        ) {
            self.liveWindowEntryIds = liveWindowEntryIds
            self.compactedEntryIds = compactedEntryIds
            self.tokensBefore = tokensBefore
            self.tokensAfter = tokensAfter
            self.stagesApplied = stagesApplied
            self.promptName = promptName
            self.pendingRuns = pendingRuns
        }

        /// The JSON keys of ``Content``.
        ///
        /// ``compactedEntryIds`` is written under its own name. A checkpoint
        /// recorded before the rename holds the same list under
        /// ``legacyCompactedEntryIds``, and ``init(from:)`` reads either key,
        /// so every checkpoint on disk still decodes.
        private enum CodingKeys: String, CodingKey {
            case liveWindowEntryIds
            case compactedEntryIds
            case legacyCompactedEntryIds = "foldedEntryIds"
            case tokensBefore
            case tokensAfter
            case stagesApplied
            case promptName
            case pendingRuns
        }

        /// Decodes the content. Reads ``compactedEntryIds`` under its own key,
        /// or under the legacy key of a checkpoint recorded before the rename.
        ///
        /// - Parameter decoder: The decoder to read from.
        /// - Throws: A `DecodingError` when a required key is absent under both names.
        package init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            liveWindowEntryIds = try container.decode([String].self, forKey: .liveWindowEntryIds)
            if let compacted = try container.decodeIfPresent([String].self, forKey: .compactedEntryIds) {
                compactedEntryIds = compacted
            } else {
                compactedEntryIds = try container.decode([String].self, forKey: .legacyCompactedEntryIds)
            }
            tokensBefore = try container.decode(Int.self, forKey: .tokensBefore)
            tokensAfter = try container.decode(Int.self, forKey: .tokensAfter)
            stagesApplied = try container.decode([String].self, forKey: .stagesApplied)
            promptName = try container.decode(String.self, forKey: .promptName)
            pendingRuns = try container.decodeIfPresent([PendingRunSummary].self, forKey: .pendingRuns)
        }

        /// Encodes the content. Writes ``compactedEntryIds`` under its own key
        /// and never under the legacy key.
        ///
        /// - Parameter encoder: The encoder to write to.
        /// - Throws: Whatever the encoder throws.
        package func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(liveWindowEntryIds, forKey: .liveWindowEntryIds)
            try container.encode(compactedEntryIds, forKey: .compactedEntryIds)
            try container.encode(tokensBefore, forKey: .tokensBefore)
            try container.encode(tokensAfter, forKey: .tokensAfter)
            try container.encode(stagesApplied, forKey: .stagesApplied)
            try container.encode(promptName, forKey: .promptName)
            try container.encodeIfPresent(pendingRuns, forKey: .pendingRuns)
        }
    }

    /// The unique identifier of this segment.
    package let id: String

    /// The compaction metadata this segment carries.
    package let content: Content

    /// Creates a segment that wraps `content`. `id` defaults to a fresh UUID.
    package init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }

    /// The flat description persisted with this segment's JSON content.
    package var description: String {
        let pendingRunsSuffix = content.pendingRuns.map { "; pending runs: \($0.count)" } ?? ""
        return "Compaction: \(content.compactedEntryIds.count) entries compacted into a "
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

    /// Builds the summary entry of an applied compaction: a `.response` with
    /// a text segment for `summaryText` (id `<entryId>-text`), a pending-runs
    /// text segment (id `<entryId>-pending-runs`) when `content.pendingRuns`
    /// is not `nil`, and the `.structure` ``CompactionSegment`` manifest.
    ///
    /// - Parameters:
    ///   - entryId: The boundary entry's `Transcript.Entry.id`.
    ///   - summaryText: The model-visible summary text.
    ///   - content: The compaction manifest the `.structure` segment wraps.
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

    /// Returns `entry` with the sizes of its checkpoint set to `tokensBefore`
    /// and `tokensAfter`. Every other segment, and the checkpoint's own id,
    /// stay as they are. An entry that carries no checkpoint returns
    /// unchanged.
    ///
    /// A session calls this to put its checkpoint on the measured scale, the
    /// scale its context fill reads, so that a restore reports the same fill
    /// as the live session.
    ///
    /// - Parameters:
    ///   - entry: The summary entry of a compaction.
    ///   - tokensBefore: The size before the compaction, on the new scale.
    ///   - tokensAfter: The size after the compaction, on the new scale.
    /// - Returns: The entry with the new sizes.
    internal static func restatingSizes(
        of entry: Transcript.Entry, tokensBefore: Int, tokensAfter: Int
    ) -> Transcript.Entry {
        guard case .response(let response) = entry else { return entry }
        let segments = response.segments.map { segment -> Transcript.Segment in
            guard case .structure(let structured) = segment,
                let checkpoint = (try? CompactionSegment(structuredSegment: structured)) ?? nil
            else { return segment }
            var content = checkpoint.content
            content.tokensBefore = tokensBefore
            content.tokensAfter = tokensAfter
            return CompactionSegment(id: checkpoint.id, content: content).transcriptSegment
        }
        return .response(Transcript.Response(id: response.id, segments: segments))
    }
}
