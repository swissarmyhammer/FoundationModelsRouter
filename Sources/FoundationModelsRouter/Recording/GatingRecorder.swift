import Foundation

/// A ``TranscriptRecorder`` that enforces a ``RecordingLevel`` and the
/// ``Router``'s `redact` hook, then forwards each event to an inner sink.
///
/// It is the one place the recording level and redaction are applied, wrapping
/// whichever concrete sink the router hands down (``JSONLRecorder``,
/// ``InMemoryRecorder``, or ``NoneRecorder``). Because every event source —
/// the session ``generate`` chokepoint and ``RoutedEmbedder/embed(_:)`` alike —
/// records through the recorder the router threaded to it, wrapping that one
/// recorder makes all of them honor the level and hook without each having to
/// know about gating:
///
/// - ``RecordingLevel/off`` drops every event, so nothing is written and no
///   transcript file is created;
/// - ``RecordingLevel/metadataOnly`` maps the body ``TranscriptEvent/text`` to
///   `nil`, keeping counts, kinds, and provenance;
/// - ``RecordingLevel/full`` keeps the body, passing it through the `redact`
///   hook first when one is set.
///
/// Gating changes only *what* an event carries (or whether it is forwarded at
/// all); the inner sink still owns `seq`/`ts` stamping and the best-effort
/// swallow of any write failure, so a failed sink write under gating is logged
/// and dropped, never surfaced into generation or embedding.
public struct GatingRecorder: TranscriptRecorder {
    /// How much of each event to record.
    private let level: RecordingLevel

    /// The redaction hook applied to body text at ``RecordingLevel/full``, or
    /// `nil` to record bodies verbatim.
    private let redact: (@Sendable (String) -> String)?

    /// The sink each gated event is forwarded to.
    private let inner: any TranscriptRecorder

    /// Creates a gating recorder wrapping `inner`.
    ///
    /// - Parameters:
    ///   - level: How much of each event to record.
    ///   - redact: The redaction hook for body text, or `nil` to record verbatim.
    ///   - inner: The sink each gated event is forwarded to.
    public init(
        level: RecordingLevel,
        redact: (@Sendable (String) -> String)?,
        wrapping inner: any TranscriptRecorder
    ) {
        self.level = level
        self.redact = redact
        self.inner = inner
    }

    /// Applies the level and redaction to `partial`, then forwards it to the
    /// inner sink — or drops it entirely at ``RecordingLevel/off``.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        switch level {
        case .off:
            return
        case .metadataOnly:
            await inner.append(partial.mapText { _ in nil }, to: directory)
        case .full:
            guard let redact else {
                await inner.append(partial, to: directory)
                return
            }
            await inner.append(partial.mapText { $0.map(redact) }, to: directory)
        }
    }
}
