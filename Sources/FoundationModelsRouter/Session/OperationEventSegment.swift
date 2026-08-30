import Foundation
import FoundationModels

/// A ``PersistableStructuredSegment`` durably recording one drained ``OperationEvent`` on the `.prompt` entry it rode into a turn.
///
/// ``RoutedSessionActor``'s turn chokepoint drains
/// `SessionOutbox.drainForDispatch()` at the start of every turn and
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
/// ``PersistableStructuredSegment`` requires, so no intermediate wrapper is
/// needed. The segment travels as a `Transcript.StructuredSegment` under the
/// schema name `FoundationModelsRouter.OperationEventSegment`, and it
/// round-trips through ``TranscriptEntryMapper/entry(from:kind:)`` with zero
/// caller setup, exactly as ``CompactionSegment`` does.
///
/// The type is internal. ``TranscriptEvent/operationEvents`` is the public entry
/// point a package outside this one reads these segments back through.
struct OperationEventSegment: PersistableStructuredSegment, Equatable, CustomStringConvertible, Sendable {
    /// A unique identifier for this segment — a fresh UUID for an event newly drained from the outbox, or the persisted id when rebuilding from disk.
    let id: String

    /// The drained ``OperationEvent`` this segment durably records.
    let content: OperationEvent

    /// Creates a segment wrapping `content`.
    ///
    /// - Parameters:
    ///   - id: This segment's id — a fresh one for an event newly drained
    ///     from the outbox, or the persisted id when rebuilding one from disk
    ///     (this initializer also satisfies ``PersistableStructuredSegment``'s
    ///     `init(id:content:) throws` requirement: a non-throwing
    ///     implementation is a valid conformance for a throwing requirement).
    ///   - content: The wrapped event.
    init(id: String = UUID().uuidString, content: OperationEvent) {
        self.id = id
        self.content = content
    }

    /// The flattened description persisted alongside this segment's JSON.
    ///
    /// This is the same rendered line the turn's preamble carries for this
    /// event (see ``renderedLine(for:)``), so the two textual views of one
    /// drained event never drift apart.
    var description: String { Self.renderedLine(for: content) }

    /// Renders one ``OperationEvent`` as a single model-legible text line.
    ///
    /// For example: `"[shell] run command (3) completed: exit 0, 2481 lines"`
    /// for a `.completed` event, `"[shell] run command (3) running: 812 lines
    /// so far"` for a `.progress` one, or `"[snippet] elicit form (3)
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

extension TranscriptEvent {
    /// Every ``OperationEvent`` this event's entry carries, in segment order.
    ///
    /// Read this off EVERY recorded event, and not off the `.toolOutput` ones
    /// alone, because this package writes one event's segment two ways. The run
    /// journal appends its own `.toolOutput` entry at the moment the event is
    /// posted, and the turn chokepoint appends the same segment again onto the
    /// turn's recorded `.prompt` entry, once per event that turn drained. A
    /// reader that took a single entry kind would see one of the two writes.
    ///
    /// A run's identity travels inside the segment and never in the entry that
    /// carries it: a `.toolOutput` entry's id is a fresh ULID by design, so an
    /// event's `correlationID` is the only place the identity of the run
    /// survives. Group and filter on that.
    ///
    /// The read is total. A segment of another case, a persisted segment under
    /// another schema name, and a segment whose body does not decode are each
    /// passed over, so one unreadable segment never costs the caller the rest of
    /// the entry.
    ///
    /// The entry point sits on ``TranscriptEvent`` — the type a caller holds
    /// already — because the segment these events are decoded from, the internal
    /// `OperationEventSegment`, is no part of this package's public surface.
    public var operationEvents: [OperationEvent] {
        (entry?.segments ?? []).compactMap { segment in
            guard let structure = segment.persistedStructure,
                structure.schemaName == OperationEventSegment.schemaName
            else { return nil }
            return try? JSONDecoder().decode(
                OperationEvent.self, from: Data(structure.contentJSON.utf8))
        }
    }
}
