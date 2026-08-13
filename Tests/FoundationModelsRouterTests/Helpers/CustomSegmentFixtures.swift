import FoundationModels

@testable import FoundationModelsRouter

/// The note body a ``TestNoteSegment`` carries — a minimal `Codable` content
/// type for tests that need a real `.custom` transcript segment.
struct TestNote: Codable, Equatable, Sendable {
    /// The note's text.
    var body: String
}

/// A shared test-only ``PersistableCustomSegment`` whose content is a
/// ``TestNote`` — the fixture for tests that put a `.custom` segment into a
/// hand-built `Transcript.Entry` (tool output segments, seeded rows) without
/// each suite declaring a private conformer of its own.
struct TestNoteSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
    /// The segment's own id.
    let id: String

    /// The note this segment carries.
    let content: TestNote

    /// Creates a segment.
    ///
    /// - Parameters:
    ///   - id: The segment's own id.
    ///   - content: The note to carry.
    init(id: String, content: TestNote) {
        self.id = id
        self.content = content
    }

    /// The flattened GUI convenience rendering the mapper persists as the
    /// segment's `description`.
    var description: String { "Note: \(content.body)" }
}
