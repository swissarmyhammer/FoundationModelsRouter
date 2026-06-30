import Foundation

/// The append-only sink a session records its transcript to.
///
/// A session is *born holding* a recorder — there is no public way to skip
/// recording, because "off" is the no-op ``NoneRecorder`` sink, not `nil`. Every
/// conforming sink shares one call path: ``append(_:)`` takes a
/// ``TranscriptEvent/Partial`` and the recorder — an actor — stamps `seq` and
/// `ts` atomically as it appends, so concurrent appends from forked sessions
/// collapse into a single totally-ordered log.
///
/// Recording is best-effort: ``append(_:)`` is non-throwing, so a sink that
/// fails to persist an event logs and drops it rather than surfacing the failure
/// into the generation path.
///
/// The three sinks are reached by leading-dot factory members so a call site can
/// write `.jsonl(directory:)`, `.inMemory`, or `.none` wherever a concrete sink
/// type is expected:
///
/// ```swift
/// let recorder: JSONLRecorder = .jsonl(directory: url)
/// let probe: InMemoryRecorder = .inMemory
/// let off: NoneRecorder = .none
/// ```
public protocol TranscriptRecorder: Sendable {
    /// Records an event, stamping it with the next monotonic `seq` and the
    /// current `ts` before it lands in the log.
    ///
    /// Best-effort and non-throwing: a persistence failure is logged and the
    /// event dropped, never raised to the caller.
    ///
    /// - Parameter partial: The event to record, minus its `seq` and `ts`.
    func append(_ partial: TranscriptEvent.Partial) async
}

extension TranscriptRecorder where Self == JSONLRecorder {
    /// A sink that appends each event as one JSON line to `transcript.jsonl`
    /// under `directory`.
    ///
    /// - Parameters:
    ///   - directory: The directory to write `transcript.jsonl` into; created on
    ///     demand at first append.
    ///   - now: The clock used to stamp each event's `ts`. Injectable so tests
    ///     can make timestamps deterministic; defaults to the system clock.
    /// - Returns: A new JSONL recorder.
    public static func jsonl(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> JSONLRecorder {
        JSONLRecorder(directory: directory, now: now)
    }
}

extension TranscriptRecorder where Self == InMemoryRecorder {
    /// A sink that collects events in memory, for tests and introspection.
    public static var inMemory: InMemoryRecorder {
        InMemoryRecorder()
    }
}

extension TranscriptRecorder where Self == NoneRecorder {
    /// The no-op sink — recording turned "off" without a `nil` recorder.
    public static var none: NoneRecorder {
        NoneRecorder()
    }
}
