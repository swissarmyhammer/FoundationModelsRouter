import Foundation
import FoundationModels

/// A ``PersistableCustomSegment`` durably recording one drained
/// ``OperationEvent`` on the `.prompt` entry it rode into a turn.
///
/// ``RoutedSessionActor``'s turn chokepoint drains
/// ``SessionOutbox/drainForDispatch()`` at the start of every turn and
/// renders each drained event as a plain-text preamble line the model reads
/// (see ``renderedLine(for:)``) — but the model never sees anything beyond
/// that flattened text, since the live `LanguageModelSession` only ever
/// accepts a plain prompt string (``LanguageModelSessionBackend``'s
/// `String`-only surface). This segment is the durable, structured
/// counterpart: the chokepoint appends one of these per drained event
/// directly onto the turn's *recorded* `.prompt` entry — never into the SDK's
/// own live transcript, only into what gets persisted — so a reader
/// reconstructing the transcript later can recover the original typed
/// ``OperationEvent`` instead of only its flattened text line.
///
/// `content` is the event itself: `OperationEvent` is already
/// `Codable & Sendable & Equatable`, exactly what
/// `Transcript.CustomSegment.Content` requires, so no intermediate wrapper is
/// needed. Round-trips through ``TranscriptEntryMapper/entry(from:kind:registry:)``
/// with zero caller setup: Router pre-registers this type in
/// ``CustomSegmentRegistry/routerDefault`` (exactly as it does
/// ``CompactionSegment``), so every default-argument reconstruction entry
/// point rebuilds it out of the box.
public struct OperationEventSegment: PersistableCustomSegment, Equatable, CustomStringConvertible {
    public let id: String
    public let content: OperationEvent

    /// Creates a segment wrapping `content`.
    ///
    /// - Parameters:
    ///   - id: This segment's id — a fresh one for an event newly drained
    ///     from the outbox, or the persisted id when rebuilding one from disk
    ///     (this initializer also satisfies ``PersistableCustomSegment``'s
    ///     `init(id:content:) throws` requirement: a non-throwing
    ///     implementation is a valid conformance for a throwing requirement).
    ///   - content: The wrapped event.
    public init(id: String = UUID().uuidString, content: OperationEvent) {
        self.id = id
        self.content = content
    }

    /// The flattened GUI/debugging description persisted alongside this
    /// segment's JSON content — the same rendered line the turn's preamble
    /// carries for this event (see ``renderedLine(for:)``), so the two
    /// textual views of one drained event never drift apart.
    public var description: String { Self.renderedLine(for: content) }

    /// Renders one ``OperationEvent`` as a single model-legible text line,
    /// e.g. `"[shell] run command (3) completed: exit 0, 2481 lines"` for a
    /// `.completed` event, `"[shell] run command (3) running: 812 lines so
    /// far"` for a `.progress` one, or `"[snippet] elicit form (3)
    /// eliciting: Which account?"` for an `.elicitation` one — an
    /// elicitation's body is its typed request's `message` (the question the
    /// user is being asked), falling back to `detail` when the typed request
    /// is absent.
    ///
    /// Shared by every drained event's preamble line
    /// (``RoutedSessionActor``'s turn chokepoint) and this segment's own
    /// ``description``, so the two textual views of one event never drift.
    ///
    /// - Parameter event: The event to render.
    /// - Returns: The one-line rendering.
    static func renderedLine(for event: OperationEvent) -> String {
        let state: String
        let body: String
        switch event.kind {
        case .progress:
            (state, body) = ("running", event.detail)
        case .completed:
            (state, body) = ("completed", event.detail)
        case .elicitation:
            (state, body) = ("eliciting", event.elicitation?.message ?? event.detail)
        }
        return "[\(event.tool)] \(event.op) (\(event.correlationID)) \(state): \(body)"
    }
}
