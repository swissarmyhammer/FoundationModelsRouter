import Foundation

/// The one fold that the restores of the write-ahead markers share.
///
/// A restore drops a marker that a later event covers. The fold of the
/// prompt markers (``OpenPrompts``) and the fold of the tool-call markers
/// (``OpenToolCalls``) both need the index of the newest event that covers a
/// key. They differ only in the keys that an event covers.
enum EventCover {
    /// The index of the newest event that covers each key.
    ///
    /// - Parameters:
    ///   - events: The events of one session, in order.
    ///   - coveredKeys: The keys that one event covers, or none.
    /// - Returns: The index of the newest covering event, by key.
    static func lastIndex<Key: Hashable>(
        in events: [TranscriptEvent], coveredKeys: (TranscriptEvent) -> [Key]
    ) -> [Key: Int] {
        var lastIndexByKey: [Key: Int] = [:]
        for (index, event) in events.enumerated() {
            for key in coveredKeys(event) {
                lastIndexByKey[key] = index
            }
        }
        return lastIndexByKey
    }
}
