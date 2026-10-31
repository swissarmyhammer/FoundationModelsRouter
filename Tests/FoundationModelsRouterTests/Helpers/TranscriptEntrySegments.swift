import FoundationModels
import FoundationModelsExtras

@testable import FoundationModelsRouter

/// Reads the segments of transcript entries, and the run events that those
/// segments carry. The suites that read the transcript a model gets share
/// these reads.
enum TranscriptEntrySegments {
    /// The segments of `entry`, or none for an entry that has no segments.
    ///
    /// - Parameter entry: A transcript entry.
    /// - Returns: The segments of the entry.
    static func segments(of entry: Transcript.Entry) -> [Transcript.Segment] {
        switch entry {
        case .instructions(let instructions):
            return instructions.segments
        case .prompt(let prompt):
            return prompt.segments
        case .response(let response):
            return response.segments
        case .reasoning(let reasoning):
            return reasoning.segments
        case .toolOutput(let output):
            return output.segments
        case .toolCalls, .data:
            return []
        @unknown default:
            return []
        }
    }

    /// The run events that the ``OperationEventSegment``s of `entries` carry.
    ///
    /// - Parameter entries: The entries of a transcript.
    /// - Returns: The decoded events, in order.
    static func operationEvents(in entries: [Transcript.Entry]) -> [OperationEvent] {
        entries.flatMap(segments(of:)).compactMap { segment in
            guard case .structure(let structure) = segment else { return nil }
            return (try? OperationEventSegment(structuredSegment: structure))??.content
        }
    }
}
