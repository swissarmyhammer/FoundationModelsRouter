import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``MailRecordSegment/removingRecords(from:)``, the read that
/// removes the mail records of a `.prompt` entry before the transcript goes
/// to a backend (task ^vn91mgt).
@Suite("MailRecordSegment: the removal of the mail records of an entry")
struct MailRecordSegmentRemovalTests {
    /// The id of the `.prompt` entry of each test.
    private static let promptID = "prompt"

    /// A text segment with the id and the text `name`.
    private static func text(_ name: String) -> Transcript.Segment {
        .text(Transcript.TextSegment(id: name, content: name))
    }

    /// A mail record segment with the id `name`, for a new mail.
    private static func record(_ name: String) -> Transcript.Segment {
        MailRecordSegment(id: name, content: .cancelled(MailID())).transcriptSegment
    }

    /// A `.prompt` entry with the id ``promptID`` and the segments `segments`.
    private static func prompt(_ segments: [Transcript.Segment]) -> Transcript.Entry {
        .prompt(Transcript.Prompt(id: promptID, segments: segments))
    }

    @Test("A prompt with mail records and text keeps the text only, in order")
    func promptKeepsTextOnly() {
        let entry = Self.prompt([Self.record("r1"), Self.text("a"), Self.record("r2"), Self.text("b")])

        let removed = MailRecordSegment.removingRecords(from: entry)

        #expect(removed == Self.prompt([Self.text("a"), Self.text("b")]))
    }

    @Test("A prompt with only mail records stays a prompt with the same id and no segments")
    func promptWithOnlyRecordsKeepsNoSegments() {
        let entry = Self.prompt([Self.record("r1"), Self.record("r2")])

        let removed = MailRecordSegment.removingRecords(from: entry)

        #expect(removed == Self.prompt([]))
    }

    @Test("An entry that is not a prompt stays as it is, mail records included")
    func entryThatIsNotPromptStays() {
        let entry = Transcript.Entry.response(Transcript.Response(segments: [Self.record("r1"), Self.text("a")]))

        let removed = MailRecordSegment.removingRecords(from: entry)

        #expect(removed == entry)
    }
}
