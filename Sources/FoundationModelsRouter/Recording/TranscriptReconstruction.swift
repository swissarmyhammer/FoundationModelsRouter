import FoundationModels
import Foundation
import os

/// The logger that reports a duplicated entry id during restore.
private let transcriptReconstructionLogger = makeModuleLogger(category: "Recording")

/// A failure reconstructing a `FoundationModels.Transcript` from a session's
/// effective entry-kind events. Each case names the event's `session` and `seq`.
public enum TranscriptReconstructionError: Error, Equatable, LocalizedError {
    /// An entry-kind event with `entry == nil`, from a v1 recording line.
    /// Reconstruction refuses it.
    case legacyEventMissingPayload(session: ULID, seq: Int)

    /// An event whose payload ``RecordingLevel/metadataOnly`` stripped
    /// (``TranscriptEntryPayload/contentRemoved`` is `true`).
    case contentRemoved(session: ULID, seq: Int)

    /// Any other ``TranscriptEntryReconstructionError`` the mapper threw, with
    /// this event's session and `seq` attached.
    case entryReconstructionFailed(session: ULID, seq: Int, underlying: TranscriptEntryReconstructionError)

    /// The newest ``CompactionSegment`` checkpoint names a live-window entry
    /// id that this session's effective events do not contain.
    case checkpointEntryMissing(session: ULID, seq: Int, entryId: String)

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
        case .entryReconstructionFailed(let session, let seq, let underlying):
            return """
                Session \(session.description) event #\(seq) could not be reconstructed: \(underlying).
                """
        case .checkpointEntryMissing(let session, let seq, let entryId):
            return """
                Session \(session.description) event #\(seq)'s CompactionSegment names live-window \
                entry id "\(entryId)", which this session's recorded events do not contain.
                """
        }
    }
}

/// Which view ``TranscriptTree/effectiveTranscript(forSession:view:)`` reconstructs.
public enum TranscriptReconstructionView: Sendable, Equatable {
    /// The newest ``CompactionSegment`` checkpoint's live window plus every
    /// entry recorded after it. A session with no checkpoint reconstructs in
    /// full. This is the default.
    case restore

    /// Every recorded entry, in `seq` order. The compaction entry appears as
    /// a fold marker among the entries it replaced.
    case fullHistory
}

extension TranscriptTree {
    /// One recorded ``CompactionSegment`` checkpoint within an ordered event array.
    struct CompactionCheckpoint: Sendable {
        /// The checkpoint event's index within the array it was found in.
        let index: Int
        /// The checkpoint event itself.
        let event: TranscriptEvent
        /// The fold metadata it carries.
        let content: CompactionSegment.Content
    }

    /// Every ``CompactionSegment`` checkpoint among `events`, oldest first.
    /// `events` must be in ``effectiveEntryEvents(forSession:)`` order.
    static func compactionCheckpoints(in events: [TranscriptEvent]) -> [CompactionCheckpoint] {
        events.enumerated().compactMap { index, event in
            compactionSegmentContent(in: event).map { CompactionCheckpoint(index: index, event: event, content: $0) }
        }
    }

    /// The newest ``CompactionSegment`` checkpoint among `events`, or `nil`.
    static func newestCompactionCheckpoint(in events: [TranscriptEvent]) -> CompactionCheckpoint? {
        compactionCheckpoints(in: events).last
    }

    /// Decodes `event`'s ``CompactionSegment/Content`` from its `.structure`
    /// segment. Returns `nil` when `event` has no compaction segment, or when
    /// its content is stripped or corrupt. Mapping the event later still
    /// throws for a stripped or corrupt payload.
    private static func compactionSegmentContent(in event: TranscriptEvent) -> CompactionSegment.Content? {
        guard event.kind == .response, let segments = event.entry?.segments else { return nil }
        for segment in segments {
            guard let structure = segment.persistedStructure,
                structure.schemaName == CompactionSegment.schemaName,
                let content = try? JSONDecoder().decode(
                    CompactionSegment.Content.self, from: Data(structure.contentJSON.utf8))
            else { continue }
            return content
        }
        return nil
    }

    /// Returns `checkpoint`'s ``CompactionSegment/Content/liveWindowEntryIds``
    /// resolved to their recorded events, then every event after the
    /// checkpoint. A duplicated entry id resolves to the newest event and is
    /// reported to the log.
    ///
    /// - Throws: ``TranscriptReconstructionError/checkpointEntryMissing(session:seq:entryId:)``.
    static func restoreFilteredEvents(
        _ events: [TranscriptEvent],
        checkpoint: CompactionCheckpoint
    ) throws -> [TranscriptEvent] {
        var byEntryId: [String: TranscriptEvent] = [:]
        for event in events {
            guard let entryId = event.entry?.entryId else { continue }
            if let superseded = byEntryId[entryId] {
                transcriptReconstructionLogger.warning(
                    """
                    duplicate entry id \(entryId, privacy: .public) in session \
                    \(checkpoint.event.sessionId.description, privacy: .public)'s effective events, \
                    at seq \(superseded.seq, privacy: .public) and seq \(event.seq, privacy: .public); \
                    restoring the newest event for this id
                    """
                )
            }
            byEntryId[entryId] = event
        }
        let liveWindow = try checkpoint.content.liveWindowEntryIds.map { entryId -> TranscriptEvent in
            guard let event = byEntryId[entryId] else {
                throw TranscriptReconstructionError.checkpointEntryMissing(
                    session: checkpoint.event.sessionId,
                    seq: checkpoint.event.seq,
                    entryId: entryId
                )
            }
            return event
        }
        let after = Array(events[(checkpoint.index + 1)...])
        return liveWindow + after
    }

    /// `rawEvents` restricted to `view`. ``TranscriptReconstructionView/fullHistory``
    /// returns `rawEvents` unchanged.
    ///
    /// - Throws: ``TranscriptReconstructionError/checkpointEntryMissing(session:seq:entryId:)``.
    static func reconstructableEvents(
        _ rawEvents: [TranscriptEvent],
        view: TranscriptReconstructionView
    ) throws -> [TranscriptEvent] {
        guard view == .restore, let checkpoint = newestCompactionCheckpoint(in: rawEvents) else {
            return rawEvents
        }
        return try restoreFilteredEvents(rawEvents, checkpoint: checkpoint)
    }

    /// The restored ``ContextUsageState`` that `events` implies, in this order:
    /// the newest stamped `.response` event after the newest checkpoint; else
    /// the checkpoint's own ``CompactionSegment/Content/tokensAfter``; else,
    /// with no checkpoint, the newest stamped `.response` event; else
    /// ``ContextUsageState/unknown``.
    ///
    /// - Parameter events: A session's raw effective events, unfiltered.
    static func restoredUsageState(in events: [TranscriptEvent]) -> ContextUsageState {
        guard let checkpoint = newestCompactionCheckpoint(in: events) else {
            return newestStampedUsage(in: events).map { .measured(input: $0.input, output: $0.output) } ?? .unknown
        }
        let afterCheckpoint = Array(events[(checkpoint.index + 1)...])
        if let stamped = newestStampedUsage(in: afterCheckpoint) {
            return .measured(input: stamped.input, output: stamped.output)
        }
        return .measured(input: checkpoint.content.tokensAfter, output: 0)
    }
}

extension TranscriptTree {
    /// Reconstructs this session's whole effective conversation as a
    /// `FoundationModels.Transcript`, usable as a `LanguageModelSession` seed.
    /// Content recorded at ``RecordingLevel/full`` round-trips. Some fields
    /// degrade as documented on ``TranscriptEntryMapper``.
    ///
    /// - Parameters:
    ///   - id: The session's span id.
    ///   - view: Which view to reconstruct. Defaults to ``TranscriptReconstructionView/restore``.
    /// - Throws: ``TranscriptTreeError`` or ``TranscriptReconstructionError``.
    public func effectiveTranscript(
        forSession id: ULID,
        view: TranscriptReconstructionView = .restore
    ) throws -> Transcript {
        let events = try Self.reconstructableEvents(effectiveEntryEvents(forSession: id), view: view)
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
                entries.append(try TranscriptEntryMapper.entry(from: payload, kind: event.kind))
            } catch TranscriptEntryReconstructionError.contentRemoved {
                throw TranscriptReconstructionError.contentRemoved(session: event.sessionId, seq: event.seq)
            } catch let underlying as TranscriptEntryReconstructionError {
                // Everything else the mapper can throw (`missingRequiredField`,
                // `invalidJSON`) — evidence of a truncated or hand-corrupted
                // log rather than one of the two documented refusals above —
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

    /// `true` when `event` is the router-only bodyless `.response` close that
    /// a failed turn emits: `entry == nil`, `text == nil`, and `ms` set. This
    /// event mirrors no `Transcript.Entry`, so reconstruction skips it. A v1
    /// turn always records a `.prompt` first, which throws before this check
    /// applies.
    private static func isFailedTurnBodylessClose(_ event: TranscriptEvent) -> Bool {
        event.kind == .response && event.entry == nil && event.text == nil && event.ms != nil
    }
}
