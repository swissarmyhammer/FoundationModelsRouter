import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``TranscriptSegmentFilter``, the shared read that removes the
/// segments of one entry that a predicate drops (task ^k8wkxj2).
@Suite("TranscriptSegmentFilter: the kept segments of one entry")
struct TranscriptSegmentFilterTests {
    /// A text segment with the id and the text `name`.
    private static func text(_ name: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(id: name, content: name))
    }

    /// Whether `segment` is the text segment with the id `name`.
    private static func isText(_ segment: Transcript.Segment, named name: String) -> Bool {
        segment == text(name)
    }

    @Test("A predicate that drops no segment gives all the segments, in order")
    func noDroppedSegmentKeepsEachSegment() {
        let segments = [Self.text("a"), Self.text("b")]

        let kept = TranscriptSegmentFilter.keptSegments(of: segments) { _ in false }

        #expect(kept == segments)
    }

    @Test("A predicate that drops some segments gives the other segments, in order")
    func droppedSegmentIsRemoved() {
        let segments = [Self.text("a"), Self.text("b"), Self.text("c")]

        let kept = TranscriptSegmentFilter.keptSegments(of: segments) { Self.isText($0, named: "b") }

        #expect(kept == [Self.text("a"), Self.text("c")])
    }

    @Test("A predicate that drops each segment gives nil")
    func droppingEachSegmentGivesNil() {
        let segments = [Self.text("a"), Self.text("b")]

        let kept = TranscriptSegmentFilter.keptSegments(of: segments) { _ in true }

        #expect(kept == nil)
    }

    @Test("An entry with no segment gives no segment, not nil")
    func noSegmentGivesNoSegment() {
        let kept = TranscriptSegmentFilter.keptSegments(of: []) { _ in true }

        #expect(kept == [])
    }
}
