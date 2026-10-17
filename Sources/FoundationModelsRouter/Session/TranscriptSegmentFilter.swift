import FoundationModels

/// The shared read that removes some segments from one transcript entry.
///
/// A read that takes a kind of segment out of the transcript that goes to a
/// backend uses this filter on the segments of one entry kind. Then it makes
/// the entry again from the kept segments. One filter gives one behavior to
/// each of these reads, for example for an entry that holds no segment after
/// the read.
enum TranscriptSegmentFilter {
    /// The segments of `segments` that `isDropped` does not drop, or `nil`
    /// when it drops at least one segment and keeps none.
    ///
    /// When `isDropped` drops no segment, the read gives `segments` as they
    /// are. Thus an entry that holds no segment before the read stays in the
    /// transcript.
    ///
    /// - Parameters:
    ///   - segments: The segments of one entry.
    ///   - isDropped: Whether to remove a segment.
    /// - Returns: The kept segments, in order, or `nil` when the read removes
    ///   each segment.
    static func keptSegments(
        of segments: [Transcript.Segment], dropping isDropped: (Transcript.Segment) -> Bool
    ) -> [Transcript.Segment]? {
        let kept = segments.filter { !isDropped($0) }
        guard kept.count != segments.count else { return segments }
        return kept.isEmpty ? nil : kept
    }
}
