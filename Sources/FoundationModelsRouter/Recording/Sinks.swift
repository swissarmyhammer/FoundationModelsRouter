import Foundation
import Logging

/// A ``TranscriptRecorder`` that appends each event as one JSON object per line
/// to a `transcript.jsonl`, routing each event to a per-session directory while
/// keeping one globally monotonic `seq`.
///
/// As an actor it serializes appends, so the single `seq` it stamps and the order
/// lines land in agree across *every* directory it writes: concurrent sessions
/// and forks appending into their own lineage-nested files still share one total
/// order. Writing is best-effort: any I/O failure is logged and the event
/// dropped — ``append(_:to:)`` never throws.
///
/// ## Durability
///
/// Each event goes through the Extras `JSONLFile` (``JSONLAppend``): one whole
/// line in one write at the end of the file, flushed with `fsync(2)` before
/// the append returns. Every event is durable the moment it lands, not only at
/// the close of a submission. A crash during an append can tear at most the
/// final line of a `transcript.jsonl`; the next append ends that torn line
/// with a newline before its own, and a read skips the torn bytes with a
/// warning (``TranscriptTree``, ``MergedTranscript``).
package actor JSONLRecorder: TranscriptRecorder {
    /// The default directory `transcript.jsonl` is written into when an append
    /// carries no explicit session directory.
    private let directory: URL
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date
    /// The next sequence number to stamp — global across all directories.
    private var seq = 0
    /// Appends one event as one line of a `transcript.jsonl`. The production
    /// append is ``JSONLAppend/toDisk``; tests inject a spy here to observe
    /// each append without disk I/O.
    private let appendLine: JSONLLineAppend
    /// The claim this recorder holds on its recording root ``directory``, so
    /// two live writers can never append into the same root. Held from
    /// construction by ``init(owningDirectory:now:)``, and taken lazily just
    /// before the first append otherwise — `nil` until then, and `nil` on
    /// every append another live writer's claim refused.
    private var rootOwnership: RecordingRootOwnership?

    /// Creates a JSONL recorder whose default directory is `directory`.
    ///
    /// Ownership of `directory` as a recording root is taken just before the
    /// first append, keeping this initializer non-throwing and writing nothing
    /// to disk until an event lands. When another live writer already owns the
    /// root, every append is logged and dropped — never interleaved — until
    /// that writer releases it. To learn about a held root at open time
    /// instead, use the throwing ``init(owningDirectory:now:)``.
    package init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(directory: directory, now: now, appendLine: JSONLAppend.toDisk)
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
    /// Unlike its sibling, this initializer touches the disk: it creates the
    /// root and writes the lock marker.
    ///
    /// - Throws: ``RecordingRootLockError/alreadyOwned(root:owner:)`` when a
    ///   live writer already owns the root, naming that owner, or
    ///   ``RecordingRootLockError/contested(root:)`` when a stale-lock takeover
    ///   loses its race; otherwise any file-system error from creating the root
    ///   or its marker, which is untyped. A `catch` over the typed cases alone
    ///   is not exhaustive.
    init(owningDirectory directory: URL, now: @escaping @Sendable () -> Date = { Date() }) throws {
        let ownership = try RecordingRootOwnership.acquire(root: directory)
        self.init(directory: directory, now: now, appendLine: JSONLAppend.toDisk, rootOwnership: ownership)
    }

    /// Creates a JSONL recorder with an injected line append, so a test can
    /// observe exactly what this recorder appends.
    ///
    /// - Parameters:
    ///   - directory: The default directory of `transcript.jsonl`.
    ///   - now: The clock that stamps each event's `ts`.
    ///   - appendLine: Appends one event as one line of a file.
    ///   - rootOwnership: The claim on `directory` when the caller already
    ///     holds it, else `nil`, so the first append takes it.
    init(
        directory: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        appendLine: @escaping JSONLLineAppend,
        rootOwnership: RecordingRootOwnership? = nil
    ) {
        self.directory = directory
        self.now = now
        self.appendLine = appendLine
        self.rootOwnership = rootOwnership
    }

    /// Stamps and appends an event into `directory`, or into the recorder's
    /// default directory when `nil`, as one line flushed to the disk (see
    /// Durability).
    ///
    /// The first append also claims the recording root (see ``rootOwnership``);
    /// while another live writer holds it, the event is logged and dropped
    /// before it is stamped, so no line ever interleaves into a root this
    /// recorder does not own and `seq` spends nothing on refused appends.
    package func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        guard ensureRootOwnership() else { return }
        let event = partial.stamped(seq: seq, ts: now())
        seq += 1
        let target = (directory ?? self.directory).appendingPathComponent(transcriptFileName, isDirectory: false)
        JSONLAppend.appendDroppingFailure(
            event,
            to: target,
            through: appendLine,
            logger: RouterTelemetry.makeLogger(.recording),
            failureMessage: "dropping a transcript event",
            failureMetadata: [RouterTelemetry.LogMetadataKey.eventSeq: "\(event.seq)"]
        )
    }

    /// Claims the recording root before a write when no claim is held yet,
    /// matching the best-effort append policy: a refusal is logged, never
    /// thrown. Retried on every refused append, so this recorder takes the root
    /// over once its current owner releases it (or dies and leaves a stale
    /// marker).
    ///
    /// - Returns: `false` when another live writer holds the root and the event
    ///   must drop.
    private func ensureRootOwnership() -> Bool {
        if rootOwnership != nil { return true }
        do {
            rootOwnership = try RecordingRootOwnership.acquire(root: directory)
            return true
        } catch {
            RouterTelemetry.makeLogger(.recording).error(
                "dropping a transcript event: the recording root has another owner",
                metadata: RouterTelemetry.errorMetadata(error))
            return false
        }
    }
}

/// A ``TranscriptRecorder`` that collects events in memory.
///
/// As an actor it serializes appends, so ``events`` is the stamped log in `seq`
/// order — contiguous from `0` — regardless of how many tasks append
/// concurrently. Intended for tests and in-process introspection.
actor InMemoryRecorder: TranscriptRecorder {
    /// The stamped events in append (and therefore `seq`) order.
    private(set) var events: [TranscriptEvent] = []
    private var seq = 0
    /// The clock used to stamp each event's `ts`.
    private let now: @Sendable () -> Date

    /// Creates an in-memory recorder.
    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Stamps and stores an event; the session directory is ignored since this
    /// sink keeps a single in-memory log rather than an on-disk layout.
    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
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
struct NoneRecorder: TranscriptRecorder {
    /// Creates the no-op sink.
    init() {}

    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {}
}
