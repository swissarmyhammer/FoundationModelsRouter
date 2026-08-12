import Foundation
import os

/// The logger best-effort sinks report dropped events to.
private let recordingLogger = makeModuleLogger(category: "Recording")

/// A ``TranscriptRecorder`` that appends each event as one JSON object per line
/// to a `transcript.jsonl`, routing each event to a per-session directory while
/// keeping one globally monotonic `seq`.
///
/// As an actor it serializes appends, so the single `seq` it stamps and the order
/// lines land in agree across *every* directory it writes: concurrent sessions
/// and forks appending into their own lineage-nested files still share one total
/// order. Each event is written to its `directory`'s `transcript.jsonl` (or the
/// recorder's own ``directory`` when the caller passes `nil`); the open handle
/// per directory is created lazily and reused. Writing is best-effort: any I/O
/// failure is logged and the event dropped — ``append(_:to:)`` never throws.
///
/// ## Durability
///
/// Each appended event is one `write` call: a whole line, written once. The
/// sync point is the turn close — after appending a `.response`-kind event
/// (the turn-final event both diff paths stamp the turn's usage onto), the
/// target directory's handle is synchronized (fsync), so a completed turn is
/// durable the moment its closing event lands. Between turn closes the window
/// is the OS's: a power cut or a kill can lose the open turn's events and can
/// tear at most the final line of a `transcript.jsonl`. That torn tail is the
/// policy's expected crash artifact, and ``TranscriptTree`` tolerates it on
/// load by dropping the torn line with a warning. Synchronization is
/// best-effort like the writes: a failed sync is logged, never thrown.
public actor JSONLRecorder: TranscriptRecorder {
    /// The default directory `transcript.jsonl` is written into when an append
    /// carries no explicit session directory.
    private let directory: URL
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date
    /// Encodes each event to a single compact JSON line (no embedded newlines).
    private let encoder = JSONEncoder()
    /// The next sequence number to stamp — global across all directories, so the
    /// whole recorder is one monotonic log.
    private var seq = 0
    /// The append handles, one per directory, opened lazily and reused across
    /// appends and keyed by the directory's standardized path.
    private var handles: [String: any TranscriptAppendHandle] = [:]
    /// Opens the append handle for a directory on first use. The production
    /// opener creates the directory and its `transcript.jsonl` on disk; tests
    /// inject a spy here to observe writes and syncs without disk I/O.
    private let openHandle: @Sendable (URL) throws -> any TranscriptAppendHandle
    /// The claim this recorder holds on its recording root ``directory``, so
    /// two live writers can never append into the same root. Held from
    /// construction by ``init(owningDirectory:now:)``, and taken lazily just
    /// before the first append otherwise — `nil` until then, and `nil` on
    /// every append another live writer's claim refused.
    private var rootOwnership: RecordingRootOwnership?

    /// The production handle opener: creates the directory and its
    /// `transcript.jsonl` on disk on first use.
    private static let productionOpenHandle: @Sendable (URL) throws -> any TranscriptAppendHandle = {
        try openHandleForAppending(fileName: "transcript.jsonl", in: $0)
    }

    /// Creates a JSONL recorder whose default directory is `directory`.
    ///
    /// Ownership of `directory` as a recording root is taken just before the
    /// first append, keeping this initializer non-throwing and writing nothing
    /// to disk until an event lands. When another live writer already owns the
    /// root, every append is logged and dropped — never interleaved — until
    /// that writer releases it. To learn about a held root at open time
    /// instead, use the throwing ``init(owningDirectory:now:)``.
    ///
    /// - Parameters:
    ///   - directory: The directory to write `transcript.jsonl` into for appends
    ///     that carry no explicit session directory; created on demand at first
    ///     append. Per-session appends are written under their own directory.
    ///   - now: The clock used to stamp each event's `ts`.
    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(
            directory: directory,
            now: now,
            openHandle: Self.productionOpenHandle
        )
    }

    /// Creates a JSONL recorder that takes ownership of `directory` as a
    /// recording root at construction — the open-time chokepoint that turns a
    /// second concurrent writer into a typed error instead of silent
    /// transcript corruption discovered at restore time.
    ///
    /// The claim spans processes (an atomically created `owner.lock` marker
    /// naming this process) and recorders within this process (a process-wide
    /// registry). A stale marker left by a crashed owner is taken over with a
    /// logged warning. The root is released when this recorder deallocates:
    /// the marker is removed and the root is immediately claimable again.
    ///
    /// - Parameters:
    ///   - directory: The recording root to own; created — along with its
    ///     lock marker — at construction.
    ///   - now: The clock used to stamp each event's `ts`.
    /// - Throws: ``RecordingRootLockError/alreadyOwned(root:owner:)`` when a
    ///   live writer already owns the root, naming that owner;
    ///   ``RecordingRootLockError/contested(root:)`` when a stale-lock
    ///   takeover loses its race; otherwise any file-system error creating
    ///   the root or its marker.
    public init(owningDirectory directory: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let ownership = try RecordingRootOwnership.acquire(root: directory)
        self.init(
            directory: directory,
            now: now,
            openHandle: Self.productionOpenHandle,
            rootOwnership: ownership
        )
    }

    /// Creates a JSONL recorder with an injected handle opener, so a test can
    /// observe exactly when this recorder writes and synchronizes.
    ///
    /// - Parameters:
    ///   - directory: The default directory for appends that carry no explicit
    ///     session directory.
    ///   - now: The clock used to stamp each event's `ts`.
    ///   - openHandle: Opens the append handle for a directory on first use.
    ///   - rootOwnership: An already-held claim on `directory` as a recording
    ///     root, or `nil` to take the claim lazily at first append.
    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        openHandle: @escaping @Sendable (URL) throws -> any TranscriptAppendHandle,
        rootOwnership: RecordingRootOwnership? = nil
    ) {
        self.directory = directory
        self.now = now
        self.openHandle = openHandle
        self.rootOwnership = rootOwnership
    }

    /// Stamps and appends an event as one JSON line into `directory`'s
    /// `transcript.jsonl` (or the recorder's default directory when `nil`); logs
    /// and drops it on any I/O failure. A `.response`-kind event is a turn
    /// close, so it additionally synchronizes the target's handle (see the
    /// type's Durability section).
    ///
    /// The first append also claims the recording root (see ``rootOwnership``);
    /// while another live writer holds it, the event is logged and dropped
    /// before it is stamped, so no line ever interleaves into a root this
    /// recorder does not own and `seq` spends nothing on refused appends.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        guard ensureRootOwnership() else { return }
        let event = partial.stamped(seq: seq, ts: now())
        seq += 1
        let target = directory ?? self.directory
        appendJSONLine(
            event,
            encoder: encoder,
            logger: recordingLogger,
            handle: { try self.handleForAppending(in: target) },
            describeFailure: { error in
                "dropping transcript event seq \(event.seq): \(error.localizedDescription)"
            }
        )
        guard event.kind == .response else { return }
        synchronizeHandle(in: target, afterSeq: event.seq)
    }

    /// Claims the recording root before a write when no claim is held yet,
    /// matching the best-effort append policy: a refusal is logged, never
    /// thrown. Retried on every refused append, so this recorder takes the
    /// root over once its current owner releases it (or dies and leaves a
    /// stale marker).
    ///
    /// - Returns: `true` when this recorder owns the root and may write;
    ///   `false` when another live writer holds it and the event must drop.
    private func ensureRootOwnership() -> Bool {
        if rootOwnership != nil { return true }
        do {
            rootOwnership = try RecordingRootOwnership.acquire(root: directory)
            return true
        } catch {
            recordingLogger.error(
                "dropping transcript event: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Best-effort fsync of `directory`'s cached append handle, called after
    /// a turn-close (`.response`-kind) append so the completed turn is durable
    /// (see the type's Durability section). A directory with no cached handle
    /// recorded nothing — the append itself already failed and was logged —
    /// so there is nothing to synchronize. A sync failure is logged, matching
    /// the best-effort write policy.
    ///
    /// - Parameters:
    ///   - directory: The directory whose append handle to synchronize.
    ///   - eventSeq: The just-appended turn-close event's sequence number,
    ///     named by the log when the sync fails.
    private func synchronizeHandle(in directory: URL, afterSeq eventSeq: Int) {
        guard let handle = handles[handleKey(for: directory)] else { return }
        do {
            try handle.synchronize()
        } catch {
            recordingLogger.error(
                """
                transcript sync after turn-close seq \(eventSeq, privacy: .public) failed: \
                \(error.localizedDescription, privacy: .public)
                """
            )
        }
    }

    /// Returns the reusable append handle for a directory, opening it (via
    /// ``openHandle``, which creates the directory and its `transcript.jsonl`
    /// in production) on first use.
    ///
    /// - Parameter directory: The directory whose `transcript.jsonl` to append to.
    /// - Returns: A handle positioned at the end of that file.
    /// - Throws: If the directory or file cannot be created or opened.
    private func handleForAppending(in directory: URL) throws -> any TranscriptAppendHandle {
        let key = handleKey(for: directory)
        if let handle = handles[key] { return handle }
        let handle = try openHandle(directory)
        handles[key] = handle
        return handle
    }

    /// The ``handles`` key for a directory: its standardized path.
    ///
    /// - Parameter directory: The directory to key.
    /// - Returns: The standardized path that identifies its cached handle.
    private func handleKey(for directory: URL) -> String {
        directory.standardizedFileURL.path
    }
}

/// A ``TranscriptRecorder`` that collects events in memory.
///
/// As an actor it serializes appends, so ``events`` is the stamped log in `seq`
/// order — contiguous from `0` — regardless of how many tasks append
/// concurrently. Intended for tests and in-process introspection.
public actor InMemoryRecorder: TranscriptRecorder {
    /// The stamped events in append (and therefore `seq`) order.
    public private(set) var events: [TranscriptEvent] = []
    /// The next sequence number to stamp.
    private var seq = 0
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date

    /// Creates an in-memory recorder.
    ///
    /// - Parameter now: The clock used to stamp each event's `ts`.
    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Stamps and stores an event; the session directory is ignored since this
    /// sink keeps a single in-memory log rather than an on-disk layout.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        events.append(partial.stamped(seq: seq, ts: now()))
        seq += 1
    }
}

/// The no-op ``TranscriptRecorder`` — recording turned "off" as a sink rather
/// than a `nil` recorder.
///
/// It stores nothing and shares the identical ``append(_:)`` call path, so a
/// session born with `.none` behaves exactly like one born with a real sink,
/// only without any record.
public struct NoneRecorder: TranscriptRecorder {
    /// Creates the no-op sink.
    public init() {}

    /// Accepts and discards an event, ignoring the session directory.
    public func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {}
}
