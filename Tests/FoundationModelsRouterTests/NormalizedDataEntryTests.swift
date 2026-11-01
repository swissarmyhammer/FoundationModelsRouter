import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing
import UniformTypeIdentifiers

/// Holds the normalizer of the tool-answer scenario to its contract for a
/// `.data` transcript entry: the entry keeps its own kind and its content
/// type, and it is not read as a reasoning entry.
@Suite("Normalizing a data transcript entry")
struct NormalizedDataEntryTests {

    @available(macOS 27.2, *)
    private static func makeDataEntry() -> Transcript.Entry {
        .data(Transcript.DataEntry(id: "data-1", contentType: .png, content: Data([0x89, 0x50])))
    }

    @Test("a data entry normalizes to a data entry that names its content type")
    func aDataEntryNormalizesToAData() {
        guard #available(macOS 27.2, *) else {
            Issue.record("The data entry needs macOS 27.2.")
            return
        }

        let normalized = [NormalizedTranscriptEntry].normalizing([Self.makeDataEntry()], markers: [])

        #expect(normalized == [.data(contentType: UTType.png.identifier)])
    }

    @Test("a data entry has the data kind")
    func aDataEntryHasTheDataKind() {
        #expect(NormalizedTranscriptEntry.data(contentType: "public.png").kind == .data)
    }
}
