import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the one fold that the open-prompt and the open-tool-call
/// restores share: the index of the newest covering event, by key.
@Suite("Index of the newest covering event")
struct LastCoveringIndexTests {
    /// An event of `kind` whose text holds the keys that it covers.
    private static func event(seq: Int, text: String?) -> TranscriptEvent {
        TranscriptEvent(
            routerId: ULID.generate(), sessionId: ULID.generate(), seq: seq,
            ts: Date(timeIntervalSince1970: TimeInterval(seq)), kind: .mail, text: text)
    }

    /// The keys in the text of `event`, split at a comma.
    private static func keys(of event: TranscriptEvent) -> [String] {
        event.text?.split(separator: ",").map(String.init) ?? []
    }

    @Test("a key that two events cover gets the index of the later event")
    func laterEventWins() {
        let events = [
            Self.event(seq: 0, text: "a,b"), Self.event(seq: 1, text: nil), Self.event(seq: 2, text: "a"),
        ]

        let indexes = EventCover.lastIndex(in: events, coveredKeys: Self.keys(of:))

        #expect(indexes == ["a": 2, "b": 0])
    }
}
