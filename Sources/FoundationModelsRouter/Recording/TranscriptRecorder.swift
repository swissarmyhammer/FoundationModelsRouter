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
    /// Records an event into a specific session directory, stamping it with the
    /// next monotonic `seq` and the current `ts` before it lands in the log.
    ///
    /// A single recorder assigns `seq` and `ts` across *all* directories it is
    /// asked to write, so the sequence is one globally monotonic total order even
    /// when concurrent sessions and forks append into their own lineage-nested
    /// transcript files. The `directory` selects *where* the event is persisted —
    /// a session passes its ``RoutedSession/recordingDirectory`` — while `seq`
    /// stays global; a sink that keeps no on-disk layout (in-memory, no-op) simply
    /// ignores it.
    ///
    /// Best-effort and non-throwing: a persistence failure is logged and the
    /// event dropped, never raised to the caller.
    ///
    /// - Parameters:
    ///   - partial: The event to record, minus its `seq` and `ts`.
    ///   - directory: The session directory to persist the event under, or `nil`
    ///     to use the recorder's own default location.
    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async
}

extension TranscriptRecorder {
    /// Records an event into the recorder's default location.
    ///
    /// The convenience for callers with no per-session directory — notably the
    /// embedding path, whose events are not tied to a session — forwarding to
    /// ``append(_:to:)`` with a `nil` directory.
    ///
    /// - Parameter partial: The event to record, minus its `seq` and `ts`.
    public func append(_ partial: TranscriptEvent.Partial) async {
        await append(partial, to: nil)
    }
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
