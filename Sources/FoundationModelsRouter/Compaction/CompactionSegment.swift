import Foundation
import FoundationModels

/// A ``PersistableStructuredSegment`` durably recording one compaction's fold
/// metadata (compaction_plan.md §1.2).
///
/// A compaction's synthesized summary entry carries two segments: a plain
/// text segment the model reads as prior context, and this segment — the
/// self-describing record of what the fold actually did:
///
/// - ``Content/liveWindowEntryIds``: the ordered `Transcript.Entry.id`s that
///   make up the compacted live window (the summary entry itself plus
///   whatever tail survived verbatim).
/// - ``Content/foldedEntryIds``: the ids of the entries the window replaced —
///   what compaction folded away. Recording *ids* rather than the folded
///   entries themselves keeps this segment small; the folded entries remain
///   forever readable from the append-only recorded transcript (see
///   compaction_plan.md §3, "Append-only, complete").
/// - ``Content/tokensBefore``/``Content/tokensAfter``: the measured transcript
///   size before and after the fold (compaction_plan.md §1.5).
/// - ``Content/stagesApplied``: which pipeline stages ran (e.g.
///   `"ToolOutputElision"`, `"TurnTruncation"`, `"Summarization"`), in order.
/// - ``Content/promptName``: the `CompactionPrompt`'s `name` used to produce
///   the summary — recorded so evals and browsers can attribute quality to
///   prompts (compaction_plan.md §2).
/// - ``Content/pendingRuns``: the run-plane summaries (token, op, latest
///   progress) of the runs still running in the session's ``SessionMailbox``
///   when the boundary was written, so a post-compaction model can rediscover
///   its in-flight work — or `nil` when there were none.
///
/// `content` is `Content`, a plain `Codable & Sendable & Equatable` struct —
/// exactly what ``PersistableStructuredSegment`` requires — so the segment
/// travels as a `Transcript.StructuredSegment` under the schema name
/// `FoundationModelsRouter.CompactionSegment`, and every reconstruction entry
/// point (``TranscriptTree/effectiveTranscript(forSession:view:)``,
/// ``RoutedModel/restoreSessionTree(root:recordingRoot:tools:)``,
/// ``RoutedModel/makeLanguageModel(resuming:)``) rebuilds a recorded
/// `CompactionSegment` with no consumer setup — see the mechanism precedent,
/// ``OperationEventSegment``, for the same round-trip shape applied to a
/// different concern.
public struct CompactionSegment: PersistableStructuredSegment, Equatable, CustomStringConvertible, Sendable {
    /// One live background run's run-plane summary, carried across the compaction
    /// boundary so a post-compaction model can rediscover its in-flight work
    /// and call `status()` for the live view.
    ///
    /// Deliberately restricted to the run plane — the same triple
    /// ``BackgroundRun`` reports (token, op, latest progress) —
    /// and never a run's output content: the boundary carries envelopes,
    /// exactly as the mailbox itself does.
    public struct PendingRunSummary: Codable, Equatable, Sendable {
        /// The run's completion token — the ULID string that is also the
        /// run's event `correlationID` and its key in the session's
        /// ``SessionMailbox``.
        public let completionToken: String

        /// The canonical `"verb noun"` op string of the background operation.
        public let op: String

        /// The latest progress detail reported for the run when the boundary
        /// was written, or `nil` when none had been reported yet.
        public let latestProgressDetail: String?

        /// Creates one background run's summary.
        ///
        /// - Parameters:
        ///   - completionToken: The run's completion token.
        ///   - op: The canonical op string of the background operation.
        ///   - latestProgressDetail: The run's latest progress detail, or
        ///     `nil` when none had been reported yet.
        public init(completionToken: String, op: String, latestProgressDetail: String?) {
            self.completionToken = completionToken
            self.op = op
            self.latestProgressDetail = latestProgressDetail
        }
    }

    /// The fold metadata one compaction's ``CompactionSegment`` carries.
    public struct Content: Codable, Equatable, Sendable {
        /// The ordered `Transcript.Entry.id`s constituting the compacted live
        /// window: the summary entry (this segment's own entry) plus whatever
        /// recent tail survived the fold verbatim.
        public var liveWindowEntryIds: [String]

        /// The `Transcript.Entry.id`s of the entries this fold replaced — what
        /// the live window used to be before compaction. The entries
        /// themselves are never deleted; they remain in the append-only
        /// recorded transcript, browsable via the `fullHistory` view.
        public var foldedEntryIds: [String]

        /// The measured transcript size, in tokens, immediately before this
        /// fold ran (compaction_plan.md §1.5 — measured, never estimated).
        public var tokensBefore: Int

        /// The measured transcript size, in tokens, immediately after this
        /// fold completed.
        public var tokensAfter: Int

        /// The pipeline stages this fold applied, in the order they ran (e.g.
        /// `["ToolOutputElision", "TurnTruncation", "Summarization"]`).
        public var stagesApplied: [String]

        /// The name of the `CompactionPrompt` used to produce this fold's
        /// summary — recorded so evals and browsers can attribute quality to
        /// prompts (compaction_plan.md §2), never the prompt's full text.
        public var promptName: String

        /// The run-plane summaries of the runs still running in the session's
        /// ``SessionMailbox`` at the moment this boundary was written, in
        /// tracking order — or `nil` when the session held none (a session with
        /// no background runs adds nothing to its boundary).
        ///
        /// Optional and synthesized-`Codable`-decoded (`decodeIfPresent`
        /// semantics), so every ``CompactionSegment`` recorded before this
        /// field existed still decodes unchanged.
        public var pendingRuns: [PendingRunSummary]?

        /// Creates fold metadata.
        ///
        /// - Parameters:
        ///   - liveWindowEntryIds: The ordered entry ids constituting the
        ///     compacted live window.
        ///   - foldedEntryIds: The entry ids this fold replaced.
        ///   - tokensBefore: The measured transcript size before the fold.
        ///   - tokensAfter: The measured transcript size after the fold.
        ///   - stagesApplied: The pipeline stages applied, in order.
        ///   - promptName: The name of the compaction prompt used.
        ///   - pendingRuns: The run-plane summaries of the runs still running
        ///     when this boundary was written, or `nil` when there were none.
        ///     Defaults to `nil`.
        public init(
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

    /// A unique identifier for this segment — a fresh UUID for newly
    /// synthesized folds, or the persisted id when rebuilding from disk.
    public let id: String

    /// The fold metadata this segment carries: live-window and folded entry
    /// ids, token counts, pipeline stages, and prompt name.
    public let content: Content

    /// Creates a segment wrapping `content`.
    ///
    /// - Parameters:
    ///   - id: This segment's id — a fresh one for a fold newly synthesized by
    ///     the compactor, or the persisted id when rebuilding one from disk
    ///     (this initializer also satisfies ``PersistableStructuredSegment``'s
    ///     `init(id:content:) throws` requirement: a non-throwing
    ///     implementation is a valid conformance for a throwing requirement).
    ///   - content: The wrapped fold metadata.
    public init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }

    /// The flattened GUI/debugging description persisted alongside this
    /// segment's JSON content.
    public var description: String {
        let pendingRunsSuffix = content.pendingRuns.map { "; pending runs: \($0.count)" } ?? ""
        return "Compaction: \(content.foldedEntryIds.count) entries folded into a "
            + "\(content.liveWindowEntryIds.count)-entry window "
            + "(\(content.tokensBefore) -> \(content.tokensAfter) tokens; "
            + "stages: \(content.stagesApplied.joined(separator: ", ")); "
            + "prompt: \(content.promptName)\(pendingRunsSuffix))"
    }

    /// Renders `pendingRuns` as the model-visible pending-run text a
    /// compaction boundary carries alongside its summary — the compacted-
    /// transcript rendering through which a post-compaction model learns its
    /// completion tokens and knows to call `status()` for the live view.
    ///
    /// Run plane only, one line per run: token, op, and latest progress —
    /// never a run's output content.
    ///
    /// - Parameter pendingRuns: The background runs' summaries, in tracking order.
    /// - Returns: The rendered pending-run text.
    ///
    /// Deliberately `internal`, matching the repo's pattern of internal
    /// statics on public types (e.g. `Compactor.estimatedTokenCount(of:)`).
    /// Two callers in this module: ``boundaryEntry(id:summaryText:content:)``
    /// renders the segment itself, and `Summarization.apply` measures the
    /// rendering's byte count so the span byte budget the final summary must
    /// fit leaves room for it (tasks ^64f3hnv, ^xx02yn6).
    internal static func renderedPendingRuns(_ pendingRuns: [PendingRunSummary]) -> String {
        let lines = pendingRuns.map { run in
            let progress = run.latestProgressDetail.map { " — latest progress: \($0)" } ?? " — no progress reported yet"
            return "- completionToken \(run.completionToken): \(run.op)\(progress)"
        }
        return """
            Background runs still pending across this compaction — call status() for the live view, \
            or wait()/cancel() with a completion token:
            \(lines.joined(separator: "\n"))
            """
    }

    /// Builds the boundary entry an applied fold appends to the conversation
    /// history — the one construction both fold paths call, so the recorded
    /// checkpoint's shape cannot drift between them. ``Summarization`` calls
    /// it with the synthesized summary; `RoutedSessionActor`'s
    /// deterministic-only fold calls it with an empty summary (task ^h1008kb).
    ///
    /// The entry is a `.response` carrying, in order: a text segment with
    /// `summaryText` (id `<entryId>-text`), an optional text segment
    /// rendering `content.pendingRuns` model-visibly (id
    /// `<entryId>-pending-runs`, present exactly when the manifest carries
    /// pending runs — see ``renderedPendingRuns(_:)``), and the `.structure`
    /// ``CompactionSegment`` manifest itself.
    ///
    /// - Parameters:
    ///   - entryId: The boundary entry's own `Transcript.Entry.id`. The text
    ///     segment ids derive from it.
    ///   - summaryText: The model-visible summary text — empty when the fold
    ///     synthesized none, because the boundary's job for the model is
    ///     then only to exist.
    ///   - content: The fold manifest the `.structure` segment wraps. Its
    ///     ``Content/pendingRuns`` decides the pending-runs segment: non-nil
    ///     renders one, `nil` adds none.
    /// - Returns: The synthesized boundary entry.
    ///
    /// Deliberately `internal`, matching ``renderedPendingRuns(_:)``: its
    /// callers are this module's two fold paths.
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
        // post-compaction model knows its tokens and can call status().
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

    /// The ``Content/promptName`` a deterministic-only fold's checkpoint
    /// carries: empty, because no summarizer read any compaction prompt —
    /// recording the prompt the fold *would* have used would attribute
    /// summary quality to a prompt that produced nothing.
    internal static let deterministicFoldPromptName = ""

    /// Returns `folded` with one synthesized boundary entry appended — the
    /// checkpoint a deterministic-only fold must still leave (tasks
    /// ^h1008kb, ^dcgkd66).
    ///
    /// The deterministic stages add no new entry ids of their own
    /// (``ToolOutputElision`` rewrites segments under the entry's original
    /// id, ``TurnTruncation`` only removes entries), so an id-diff over
    /// `folded` alone would record no checkpoint and a restore would rebuild
    /// the whole pre-fold history. Both fold paths — `RoutedSessionActor`'s
    /// in-place `compact()` swap and the bare-recipe
    /// ``RecordingLanguageModel/noteCompaction(_:result:)`` — append their
    /// deterministic boundary through this one construction, built on
    /// ``boundaryEntry(id:summaryText:content:)`` with an empty summary
    /// (there is no summary to show the model) and
    /// ``deterministicFoldPromptName``, so the two recorded boundary shapes
    /// cannot drift apart.
    ///
    /// - Parameters:
    ///   - folded: The transcript the deterministic pipeline produced.
    ///   - preFoldEntryIds: The entry ids of the transcript before the fold
    ///     ran; the ones absent from `folded` become
    ///     ``Content/foldedEntryIds``.
    ///   - tokensBefore: The pre-fold transcript size written to the
    ///     checkpoint — measured where the caller holds a measurement (the
    ///     session path), else the pipeline's estimate (the bare recipe).
    ///   - tokensAfter: The post-fold transcript size written to the
    ///     checkpoint, on the same scale as `tokensBefore`.
    ///   - stagesApplied: The pipeline stages the fold applied, in order.
    ///   - pendingRuns: The run-plane summaries of the runs still running
    ///     when the boundary was written, or `nil` when there were none.
    /// - Returns: `folded` plus the boundary entry, in that order — the
    ///   boundary names itself last in its own live window.
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
