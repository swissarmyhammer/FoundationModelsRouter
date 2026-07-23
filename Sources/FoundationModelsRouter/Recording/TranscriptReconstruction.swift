import FoundationModels
import Foundation

/// A failure reconstructing a `FoundationModels.Transcript` from a session's
/// effective entry-kind events — thrown by
/// ``TranscriptTree/effectiveTranscript(forSession:registry:)``.
///
/// Faithful reconstruction is a property of `full`-level recordings only
/// (see plan.md's "Transcript fidelity" section, "Honest fidelity scope"):
/// each case below names the offending event's `session` and `seq` rather
/// than just an entry id, since a tree can span many sessions and any one
/// event may be buried deep in an on-disk log.
public enum TranscriptReconstructionError: Error, Equatable, LocalizedError {
    /// An entry-kind event with `entry == nil` — a v1 recording line,
    /// written before the ``TranscriptEvent/entry`` field existed.
    /// Reconstruction needs the structural payload
    /// ``TranscriptEntryMapper/entry(from:kind:registry:)`` reads; a v1 line
    /// has none, so this refuses rather than fabricating an entry from the
    /// flattened ``TranscriptEvent/text`` alone.
    case legacyEventMissingPayload(session: ULID, seq: Int)

    /// An event whose payload was stripped by the recording level
    /// (``TranscriptEntryPayload/contentRemoved`` is `true` — recorded at
    /// ``RecordingLevel/metadataOnly``). The shape survives on disk (kinds,
    /// ids, counts) for a GUI to render, but reconstruction refuses rather
    /// than rebuilding an empty or fabricated entry.
    case contentRemoved(session: ULID, seq: Int)

    /// A `.custom` segment's persisted type-discriminator has no
    /// corresponding type registered in the ``CustomSegmentRegistry`` passed
    /// to reconstruction — surfaced from
    /// ``TranscriptEntryMapper/entry(from:kind:registry:)`` and re-thrown
    /// with this event's session and `seq` attached.
    case unregisteredCustomSegmentType(session: ULID, seq: Int, discriminator: String)

    /// Any other ``TranscriptEntryReconstructionError`` the mapper threw —
    /// ``TranscriptEntryReconstructionError/missingRequiredField(entryId:field:)``
    /// or ``TranscriptEntryReconstructionError/invalidJSON(context:underlying:)``,
    /// evidence of a truncated or hand-corrupted on-disk log rather than one
    /// of the three documented, expected refusals above — re-thrown with
    /// this event's session and `seq` attached so every mapper failure,
    /// documented or not, carries the same locatable context.
    case entryReconstructionFailed(session: ULID, seq: Int, underlying: TranscriptEntryReconstructionError)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .legacyEventMissingPayload(let session, let seq):
            return """
                Session \(session.description) event #\(seq) has no entry payload — a v1 recording \
                line predating structural payloads — so it cannot be reconstructed into a \
                Transcript.Entry.
                """
        case .contentRemoved(let session, let seq):
            return """
                Session \(session.description) event #\(seq)'s content was stripped by the recording \
                level (metadataOnly), so it cannot be honestly reconstructed into a Transcript.Entry.
                """
        case .unregisteredCustomSegmentType(let session, let seq, let discriminator):
            return """
                Session \(session.description) event #\(seq) has a .custom segment with \
                discriminator "\(discriminator)", which is not registered in the CustomSegmentRegistry \
                passed to reconstruction.
                """
        case .entryReconstructionFailed(let session, let seq, let underlying):
            return """
                Session \(session.description) event #\(seq) could not be reconstructed: \(underlying).
                """
        }
    }
}

extension TranscriptTree {
    /// Reconstructs this session's whole effective conversation as a real,
    /// SDK-native `FoundationModels.Transcript` — directly usable as the
    /// `LanguageModelSession(model:tools:transcript:)` seed (see plan.md's
    /// "Transcript fidelity" section, "Reconstruction end-to-end").
    ///
    /// Maps ``effectiveEntryEvents(forSession:)`` through
    /// ``TranscriptEntryMapper/entry(from:kind:registry:)`` and wraps the
    /// result in `Transcript(entries:)` — the SDK's own public initializer
    /// (verified in the macOS 27 `arm64e-apple-macos.swiftinterface`).
    ///
    /// **Fidelity scope.** Lossless for text/structured/tool content
    /// recorded at ``RecordingLevel/full``: instructions, text
    /// prompts/responses, guided structured responses, and tool traffic
    /// round-trip exactly. `.custom` segments round-trip via `registry`
    /// (solved, not lossy — an unregistered discriminator is the typed
    /// error below, never a silent drop). `GenerationOptions.sampling`, the
    /// `Prompt`/`ToolCall`/`Response`/`Reasoning` `metadata` dictionaries,
    /// `Prompt.contextOptions`, URL-less attachments, and attachment bytes
    /// degrade as documented on ``TranscriptEntryMapper``.
    ///
    /// - Parameters:
    ///   - id: The session's span id.
    ///   - registry: The registered ``PersistableCustomSegment`` types a
    ///     `.custom` segment in this session's effective transcript may need
    ///     to rebuild. Defaults to ``CustomSegmentRegistry/routerDefault``
    ///     (pre-seeded with ``CompactionSegment``), so a compacted session
    ///     restores with no caller setup; any *other* recorded `.custom`
    ///     segment still throws
    ///     ``TranscriptReconstructionError/unregisteredCustomSegmentType(session:seq:discriminator:)``
    ///     unless the caller supplies a registry that also knows about it.
    /// - Returns: The reconstructed transcript.
    /// - Throws: Everything ``effectiveEntryEvents(forSession:)`` throws
    ///   (``TranscriptTreeError``), plus ``TranscriptReconstructionError``
    ///   when an event cannot be honestly rebuilt.
    public func effectiveTranscript(
        forSession id: ULID,
        registry: CustomSegmentRegistry = .routerDefault
    ) throws -> Transcript {
        let events = try effectiveEntryEvents(forSession: id)
        var entries: [Transcript.Entry] = []
        entries.reserveCapacity(events.count)
        for event in events {
            if Self.isFailedTurnBodylessClose(event) {
                continue
            }
            guard let payload = event.entry else {
                throw TranscriptReconstructionError.legacyEventMissingPayload(session: event.sessionId, seq: event.seq)
            }
            do {
                entries.append(try TranscriptEntryMapper.entry(from: payload, kind: event.kind, registry: registry))
            } catch TranscriptEntryReconstructionError.contentRemoved {
                throw TranscriptReconstructionError.contentRemoved(session: event.sessionId, seq: event.seq)
            } catch TranscriptEntryReconstructionError.unregisteredCustomSegmentType(let discriminator) {
                throw TranscriptReconstructionError.unregisteredCustomSegmentType(
                    session: event.sessionId,
                    seq: event.seq,
                    discriminator: discriminator
                )
            } catch let underlying as TranscriptEntryReconstructionError {
                // Everything else the mapper can throw (`missingRequiredField`,
                // `invalidJSON`) — evidence of a truncated or hand-corrupted
                // log rather than one of the three documented refusals above —
                // still gets the same session/seq context attached rather than
                // leaking out uncontextualized.
                throw TranscriptReconstructionError.entryReconstructionFailed(
                    session: event.sessionId,
                    seq: event.seq,
                    underlying: underlying
                )
            }
        }
        return Transcript(entries: entries)
    }

    /// Whether `event` is the router-only bodyless `.response`-kind close a
    /// failed turn's throw path emits — `entry == nil`, `text == nil`, and
    /// `ms` set, with no SDK entry behind it at all (see
    /// `RoutedSessionActor.generate(grammar:_:)`'s catch path, which emits
    /// this exactly when the SDK's own transcript diff did *not* already
    /// include a `.response`-kind entry for the failing turn).
    ///
    /// This event mirrors no `Transcript.Entry` — the SDK appended nothing
    /// durable for the turn, so there is nothing honest to rebuild — so
    /// reconstruction skips it deliberately rather than treating its
    /// `entry == nil` as a v1 legacy line
    /// (``TranscriptReconstructionError/legacyEventMissingPayload(session:seq:)``).
    /// Skipping here, rather than throwing, keeps a recording with failed
    /// turns reconstructable end-to-end: the failure already surfaced at
    /// record time (the turn's caller saw it thrown); reconstruction should
    /// not also refuse an otherwise-healthy session just because one of its
    /// turns didn't durably append anything to the SDK's own transcript.
    ///
    /// **Why this shape is safe to skip, not just plausible.** In isolation
    /// this shape is not fully unique: a genuine pre-v2 `.response` event
    /// recorded at `RecordingLevel/metadataOnly` decodes identically (no
    /// `entry` field existed yet; `text` was stripped; `ms` was stamped on
    /// every `.response` close, success or failure alike, by that era's
    /// bracketing code — see `RoutedSession.swift`'s git history at commit
    /// `06f8d16`, the last commit before the entry-shaped schema landed).
    /// Two facts together close the ambiguity, one per source of the shape:
    ///
    /// - **A genuine v1 turn is never missing its `.prompt` sibling.** That
    ///   era's bracket wrote `await append(makePartialEvent(kind: .prompt,
    ///   ...))` *unconditionally*, before ever calling into the backend —
    ///   so even a turn that failed instantly still left a `.prompt` event
    ///   on disk, one `seq` before its `.response`. ``effectiveTranscript(forSession:registry:)``
    ///   processes `events` in `seq` order and throws immediately on the
    ///   first unresolvable event, and `.prompt` is never `.response`-kind,
    ///   so this check never applies to it: a genuine v1 turn's `.prompt`
    ///   event always throws
    ///   ``TranscriptReconstructionError/legacyEventMissingPayload(session:seq:)``
    ///   first, before its `.response` sibling is ever reached — *unless*
    ///   that `.prompt` event is itself missing from the stream.
    /// - **A v2 turn's `.response` *can* be missing its `.prompt` sibling —
    ///   but only when this event is genuinely the router's synthetic
    ///   close.** Unlike v1, v2 only ever records a `.prompt`/`.instructions`
    ///   event once `recordTranscriptDelta(grammar:since:)` observes the SDK
    ///   backend durably appended one; a turn the backend rejects before
    ///   appending anything at all (e.g. a guardrail refusal on a session's
    ///   very first turn) leaves *only* the synthetic close in that
    ///   session's file — no `.prompt` at any `seq`. That exact "sole
    ///   entry-kind event is a bare `.response`" shape is one a genuine v1
    ///   recording can never produce (v1's unconditional prompt-first write
    ///   guarantees the opposite), so it unambiguously identifies a v2
    ///   recording, where a `.response`-kind event with `entry == nil` can
    ///   only ever be this synthetic close — a real v2 `.response` mapped
    ///   from an SDK entry always has `entry` populated (possibly
    ///   content-stripped, but never `nil` — see
    ///   ``TranscriptEntryPayload/strippingContent()``).
    private static func isFailedTurnBodylessClose(_ event: TranscriptEvent) -> Bool {
        event.kind == .response && event.entry == nil && event.text == nil && event.ms != nil
    }
}
