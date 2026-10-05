import Foundation

/// A ``PersistableStructuredSegment`` that records one stop of the repetition
/// watch in the run journal (task ^0dcsd3t).
///
/// The session records this segment on a ``TranscriptEvent/Kind/watchStop``
/// event after the entries of the stopped attempt. A host that reads the
/// journal reads the kind of the stop, its tokens, its limit and its
/// recovery from the ``WatchStop`` it carries. A restore skips the event.
/// The segment travels under the schema name
/// `FoundationModelsRouter.WatchStopSegment`.
struct WatchStopSegment: PersistableStructuredSegment, Equatable, Sendable {
    /// The stable name that identifies this segment on disk.
    static let schemaName = "FoundationModelsRouter.WatchStopSegment"

    /// The unique identifier of this segment.
    let id: String

    /// The stop this segment carries.
    let content: WatchStop

    /// Creates a segment that wraps `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's id. Defaults to a fresh UUID.
    ///   - content: The stop.
    init(id: String = UUID().uuidString, content: WatchStop) {
        self.id = id
        self.content = content
    }

    /// The payload of the ``TranscriptEvent/Kind/watchStop`` event that
    /// records this segment. The payload's entry id is the segment id,
    /// because the event mirrors no transcript entry.
    var eventPayload: TranscriptEntryPayload {
        TranscriptEntryPayload(entryId: id, segments: [TranscriptEntryMapper.segmentPayload(self)])
    }
}
