import Foundation
import FoundationModels

/// A ``PersistableStructuredSegment`` that records one repetition stop's cut
/// of the render (task ^gg49g5e).
///
/// After a repetition stop, ``RepeatedPartRemoval`` removes the repeated part
/// of the stopped attempt from the render that the model receives next. The
/// recorded transcript keeps each entry whole. So the session records this
/// segment on a ``TranscriptEvent/Kind/repeatedPartRemoval`` event, after the
/// entries of the stopped attempt. A restore reads it and cuts the same
/// entries of the rebuilt render (``TranscriptTree/effectiveTranscript(forSession:view:)``),
/// as it reads a ``CompactionSegment`` checkpoint. The segment travels under
/// the schema name `FoundationModelsRouter.RepeatedPartRemovalSegment`.
struct RepeatedPartRemovalSegment: PersistableStructuredSegment, Equatable, CustomStringConvertible, Sendable {
    /// The stable name that identifies this segment on disk. The write side
    /// (``eventPayload``) writes it, and the read side
    /// (``PersistableStructuredSegment/init(schemaName:contentJSON:id:)``)
    /// reads only a segment that carries it. It is the same value as the
    /// default of ``PersistableStructuredSegment/schemaName``, so a journal
    /// that an earlier build wrote stays readable.
    static let schemaName = "FoundationModelsRouter.RepeatedPartRemovalSegment"

    /// The cut that one repetition stop made.
    struct Content: Codable, Equatable, Sendable {
        /// For each watched entry id, the UTF-8 length of its text that the
        /// render keeps. See ``RepetitionFinding/keptUTF8Lengths``.
        let keptUTF8Lengths: [String: Int]
    }

    /// The unique identifier of this segment.
    let id: String

    /// The cut this segment carries.
    let content: Content

    /// Creates a segment that wraps `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's id. Defaults to a fresh UUID.
    ///   - content: The cut.
    init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }

    /// The flat description recorded as the event's text: each watched entry
    /// id with the UTF-8 length the render keeps, in id order.
    var description: String {
        let entries = content.keptUTF8Lengths.sorted { $0.key < $1.key }
            .map { "\($0.key) keeps \($0.value) UTF-8 bytes" }
        return "Repeated part removed from the render: \(entries.joined(separator: "; "))"
    }

    /// The payload of the ``TranscriptEvent/Kind/repeatedPartRemoval`` event
    /// that records this segment. The payload's entry id is the segment id,
    /// because the event mirrors no transcript entry. The one segment of the
    /// payload is this segment itself, under ``schemaName``.
    var eventPayload: TranscriptEntryPayload {
        TranscriptEntryPayload(entryId: id, segments: [TranscriptEntryMapper.segmentPayload(self)])
    }
}
