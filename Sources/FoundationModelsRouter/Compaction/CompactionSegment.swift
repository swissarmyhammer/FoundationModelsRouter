import Foundation
import FoundationModels

/// A ``PersistableCustomSegment`` durably recording one compaction's fold
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
///
/// `content` is `Content`, a plain `Codable & Sendable & Equatable` struct —
/// exactly what `Transcript.CustomSegment.Content` requires — so this segment
/// round-trips through ``TranscriptEntryMapper/entry(from:kind:registry:)``
/// with zero schema work once a registry knows about it. Router pre-registers
/// this type in ``CustomSegmentRegistry/routerDefault``, so every default-
/// argument reconstruction entry point (``TranscriptTree/effectiveTranscript(forSession:registry:)``,
/// ``RoutedModel/restoreSessionTree(root:registry:)``,
/// ``RoutedModel/makeLanguageModel(resuming:registry:)``) rebuilds a recorded
/// `CompactionSegment` with no consumer setup — see the mechanism precedent,
/// ``OperationEventSegment``, for the same round-trip shape applied to a
/// different concern.
public struct CompactionSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
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
        public init(
            liveWindowEntryIds: [String],
            foldedEntryIds: [String],
            tokensBefore: Int,
            tokensAfter: Int,
            stagesApplied: [String],
            promptName: String
        ) {
            self.liveWindowEntryIds = liveWindowEntryIds
            self.foldedEntryIds = foldedEntryIds
            self.tokensBefore = tokensBefore
            self.tokensAfter = tokensAfter
            self.stagesApplied = stagesApplied
            self.promptName = promptName
        }
    }

    public let id: String
    public let content: Content

    /// Creates a segment wrapping `content`.
    ///
    /// - Parameters:
    ///   - id: This segment's id — a fresh one for a fold newly synthesized by
    ///     the compactor, or the persisted id when rebuilding one from disk
    ///     (this initializer also satisfies ``PersistableCustomSegment``'s
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
        "Compaction: \(content.foldedEntryIds.count) entries folded into a "
            + "\(content.liveWindowEntryIds.count)-entry window "
            + "(\(content.tokensBefore) -> \(content.tokensAfter) tokens; "
            + "stages: \(content.stagesApplied.joined(separator: ", ")); "
            + "prompt: \(content.promptName))"
    }
}
