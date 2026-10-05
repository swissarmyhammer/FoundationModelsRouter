import Foundation
import FoundationModels

/// One range of UTF-8 bytes of the text of a watched entry that the render
/// keeps (task ^0dcsd3t): the lines of the range, each with its line feed.
struct KeptUTF8Range: Codable, Equatable, Sendable {
    /// The UTF-8 offset of the first byte of the range.
    let start: Int

    /// The UTF-8 offset after the last byte of the range.
    let end: Int
}

/// A ``PersistableStructuredSegment`` that records how one stop of the
/// repetition watch changed the render (tasks ^gg49g5e and ^0dcsd3t).
///
/// After a stop, ``RepeatedPartRemoval`` removes the repeated part of the
/// stopped attempt from the render that the model receives next, and closes
/// the reasoning that the stop cut off (``ReasoningClosure``). The recorded
/// transcript keeps each entry whole and holds no closing entry. So the
/// session records this segment on a
/// ``TranscriptEvent/Kind/repeatedPartRemoval`` event, after the entries of
/// the stopped attempt. A restore reads it and makes the same change of the
/// rebuilt render (``TranscriptTree/effectiveTranscript(forSession:view:)``),
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

    /// The change of the render that one stop made.
    struct Content: Codable, Equatable, Sendable {
        /// For each watched entry id, the UTF-8 length of its text that the
        /// render keeps at most. See ``RepetitionFinding/keptUTF8Lengths``.
        let keptUTF8Lengths: [String: Int]

        /// For each watched entry id, the ranges of its text that the render
        /// keeps: its lines that are not repeats
        /// (``RepetitionFinding/keptUTF8Ranges``, task ^0dcsd3t). `nil` in a
        /// journal from before that task: the render then keeps each entry
        /// up to its length in ``keptUTF8Lengths``.
        let keptUTF8Ranges: [String: [KeptUTF8Range]]?

        /// The response that closes the reasoning that the stop cut off, or
        /// `nil` when the render needs none, or in a journal from before
        /// task ^0dcsd3t.
        let reasoningClosure: ReasoningClosure?

        /// Creates the change of one stop.
        ///
        /// - Parameters:
        ///   - keptUTF8Lengths: For each watched entry id, the UTF-8 length
        ///     that the render keeps at most.
        ///   - keptUTF8Ranges: For each watched entry id, the ranges that the
        ///     render keeps, or `nil`.
        ///   - reasoningClosure: The response that closes the stopped
        ///     reasoning, or `nil`.
        init(
            keptUTF8Lengths: [String: Int], keptUTF8Ranges: [String: [KeptUTF8Range]]? = nil,
            reasoningClosure: ReasoningClosure? = nil
        ) {
            self.keptUTF8Lengths = keptUTF8Lengths
            self.keptUTF8Ranges = keptUTF8Ranges
            self.reasoningClosure = reasoningClosure
        }

        /// Whether the change changes the render: it cuts an entry or closes
        /// a reasoning.
        var changesRender: Bool {
            !keptUTF8Lengths.isEmpty || reasoningClosure != nil
        }
    }

    /// The unique identifier of this segment.
    let id: String

    /// The change this segment carries.
    let content: Content

    /// Creates a segment that wraps `content`.
    ///
    /// - Parameters:
    ///   - id: The segment's id. Defaults to a fresh UUID.
    ///   - content: The change.
    init(id: String = UUID().uuidString, content: Content) {
        self.id = id
        self.content = content
    }

    /// The flat description recorded as the event's text: each watched entry
    /// id with the UTF-8 length the render keeps, in id order, and the
    /// closed reasoning when there is one.
    var description: String {
        let entries = content.keptUTF8Lengths.sorted { $0.key < $1.key }
            .map { "\($0.key) keeps \($0.value) UTF-8 bytes" }
        let removal = "Repeated part removed from the render: \(entries.joined(separator: "; "))"
        guard let closure = content.reasoningClosure else { return removal }
        return "\(removal). Reasoning closed after \(closure.afterEntryId)"
    }

    /// The payload of the ``TranscriptEvent/Kind/repeatedPartRemoval`` event
    /// that records this segment. The payload's entry id is the segment id,
    /// because the event mirrors no transcript entry. The one segment of the
    /// payload is this segment itself, under ``schemaName``.
    var eventPayload: TranscriptEntryPayload {
        TranscriptEntryPayload(entryId: id, segments: [TranscriptEntryMapper.segmentPayload(self)])
    }
}
