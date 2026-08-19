import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Holds ``TranscriptEntryKinds`` to its contract: the kind-listing helper
/// the recorded-fixture suite and the `RecordCompactionFixture` tool share
/// (task `^4bb3mjv`).
@Suite("TranscriptEntryKinds names each entry kind once (task ^4bb3mjv)")
struct TranscriptEntryKindsTests {

    @Test("each kind is named once, in the order the kinds first appear")
    func eachKindIsNamedOnceInFirstAppearanceOrder() throws {
        let entries: [Transcript.Entry] =
            [TranscriptFixtures.makeInstructions()]
            + (try TranscriptFixtures.makeTurn(index: 1, toolOutputText: "tool result"))
            + (try TranscriptFixtures.makeTurn(index: 2))

        let names = TranscriptEntryKinds.names(of: Transcript(entries: entries))

        // Two turns carry repeated prompts and responses; each kind is still
        // named one time, at its first appearance.
        #expect(names == ["instructions", "prompt", "toolCalls", "toolOutput", "response"])
    }

    @Test("a reasoning entry is named, so a recording that kept its reasoning shows it")
    func aReasoningEntryIsNamed() {
        let entries: [Transcript.Entry] = [
            .reasoning(
                Transcript.Reasoning(
                    id: "reasoning-1",
                    segments: [.text(Transcript.TextSegment(content: "thinking"))],
                    signature: nil))
        ]

        let names = TranscriptEntryKinds.names(of: Transcript(entries: entries))

        #expect(names == ["reasoning"])
    }

    @Test("realTrafficKinds names exactly the six kinds a recorded conversation must carry")
    func realTrafficKindsCoverEveryRecordedKind() throws {
        // The recorded fixture's own conversation carries every one of these
        // kinds; the tool and the suite both check presence against this
        // list, so the list and `names(of:)` must speak the same vocabulary.
        let entries: [Transcript.Entry] =
            [TranscriptFixtures.makeInstructions()]
            + (try TranscriptFixtures.makeTurn(index: 1, toolOutputText: "tool result"))
            + [
                .reasoning(
                    Transcript.Reasoning(
                        id: "reasoning-1",
                        segments: [.text(Transcript.TextSegment(content: "thinking"))],
                        signature: nil))
            ]

        let names = TranscriptEntryKinds.names(of: Transcript(entries: entries))

        #expect(Set(names) == Set(TranscriptEntryKinds.realTrafficKinds))
    }
}
