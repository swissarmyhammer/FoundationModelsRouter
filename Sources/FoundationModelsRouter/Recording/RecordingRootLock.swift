import Foundation
import os

/// The logger recording-root ownership reports stale-lock takeovers to.
private let lockLogger = makeModuleLogger(category: "Recording")

/// The lock-marker file name a writer creates inside a recording root it
/// owns. The marker's payload is one JSON-encoded ``RecordingRootOwner``;
/// ``RecordingRootOwnership/acquire(root:)`` creates it and the owning
/// recorder's teardown removes it.
public let recordingRootLockFileName = "owner.lock"

/// The POSIX permission bits a fresh lock marker is created with
/// (owner read/write, group and others read).
private let lockFileMode: mode_t = 0o644

/// The writer that holds a recording root: which process took ownership and
/// when. Serves two roles: the lock marker's on-disk JSON payload, and the
/// owner ``RecordingRootLockError/alreadyOwned(root:owner:)`` names when a
/// second writer is refused.
public struct RecordingRootOwner: Codable, Equatable, Sendable {
    /// The owning process's id.
    public let processId: Int32
    /// When the owner took the root.
    public let acquiredAt: Date

    /// Creates an owner record.
    ///
    /// - Parameters:
    ///   - processId: The owning process's id.
    ///   - acquiredAt: When the owner took the root.
    public init(processId: Int32, acquiredAt: Date) {
        self.processId = processId
        self.acquiredAt = acquiredAt
    }
}

/// A typed failure taking ownership of a recording root, thrown at open time
/// — ``JSONLRecorder/init(owningDirectory:now:)`` — rather than surfacing as
/// corruption at restore time.
public enum RecordingRootLockError: Error, Equatable, LocalizedError {
    /// Another live writer owns the root. The root is never silently shared
    /// and never silently stolen: the caller learns which process holds it
    /// and since when.
    case alreadyOwned(root: URL, owner: RecordingRootOwner)

    /// A different writer re-created the root's lock marker in the window
    /// between a stale marker's removal and this claim's own marker landing —
    /// the takeover race was lost.
    case contested(root: URL)

    /// A localized message describing what error occurred, for `LocalizedError` conformance.
    public var errorDescription: String? {
        switch self {
        case .alreadyOwned(let root, let owner):
            return
                "recording root \(root.path) is owned by process \(owner.processId) since \(owner.acquiredAt)"
        case .contested(let root):
            return "recording root \(root.path) was claimed by another writer during a stale-lock takeover"
        }
    }
}

/// The process-wide set of recording roots currently owned by a live
/// ``RecordingRootOwnership`` in this process, keyed by canonical root path.
///
/// The on-disk marker alone cannot refuse a second writer in the *same*
/// process — its recorded pid is this process's own pid, which is always
/// alive — so this registry is the in-process layer of the guard.
private final class RecordingRootRegistry: @unchecked Sendable {
    /// The one registry for the process.
    static let shared = RecordingRootRegistry()

    /// Guards ``owners``. A lock rather than an actor because release runs
    /// synchronously from ``RecordingRootOwnership``'s `deinit`, which cannot
    /// await. Synchronization invariant: ``owners`` is only read or written
    /// while this lock is held.
    private let lock = NSLock()

    /// The current in-process owner per canonical root path.
    private var owners: [String: RecordingRootOwner] = [:]

    /// Claims `path` for `owner`.
    ///
    /// - Parameters:
    ///   - path: The canonical root path to claim.
    ///   - owner: The claiming owner record.
    /// - Returns: `nil` on success, or the already-registered owner when the
    ///   path is held by another live claim in this process.
    func claim(_ path: String, for owner: RecordingRootOwner) -> RecordingRootOwner? {
        lock.withLock {
            if let existing = owners[path] { return existing }
            owners[path] = owner
            return nil
        }
    }

    /// Releases `path`, making it claimable again.
    ///
    /// - Parameter path: The canonical root path to release.
    func release(_ path: String) {
        lock.withLock { _ = owners.removeValue(forKey: path) }
    }
}

/// A held claim on one recording root — the guard that keeps two live writers
/// from ever appending into the same root.
///
/// ``acquire(root:)`` takes the claim through two layers: an in-process
/// registry (a second recorder in this process is refused immediately) and an
/// atomically created on-disk lock marker (a writer in another process is
/// refused by the marker's live pid). A marker whose owner is no longer
/// running is stale and is taken over with a logged warning, so a crashed
/// owner never permanently bricks its root.
///
/// The claim is released by `deinit` — RAII — so clean shutdown is simply the
/// owning recorder's deallocation: the marker is removed and the registry
/// entry cleared, and the root is immediately claimable again.
final class RecordingRootOwnership: Sendable {
    /// The canonical root path registered in the in-process registry.
    private let canonicalPath: String

    /// The on-disk lock marker this claim created.
    private let lockFileURL: URL

    /// Wraps an already-acquired claim; only ``acquire(root:)`` constructs one.
    ///
    /// - Parameters:
    ///   - canonicalPath: The canonical root path registered in the registry.
    ///   - lockFileURL: The on-disk lock marker the claim created.
    private init(canonicalPath: String, lockFileURL: URL) {
        self.canonicalPath = canonicalPath
        self.lockFileURL = lockFileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: lockFileURL)
        RecordingRootRegistry.shared.release(canonicalPath)
    }

    /// Takes ownership of `root` for this process, creating the root
    /// directory and its lock marker on disk.
    ///
    /// - Parameter root: The recording root to own.
    /// - Returns: The held claim; dropping it releases the root.
    /// - Throws: ``RecordingRootLockError/alreadyOwned(root:owner:)`` when a
    ///   live writer — in this process or another — holds the root;
    ///   ``RecordingRootLockError/contested(root:)`` when a stale-lock
    ///   takeover loses its race; otherwise any file-system error creating
    ///   the directory or marker.
    static func acquire(root: URL) throws -> RecordingRootOwnership {
        let canonicalPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let claim = RecordingRootOwner(
            processId: ProcessInfo.processInfo.processIdentifier,
            acquiredAt: Date()
        )
        if let existing = RecordingRootRegistry.shared.claim(canonicalPath, for: claim) {
            throw RecordingRootLockError.alreadyOwned(root: root, owner: existing)
        }
        do {
            let lockFileURL = try writeMarker(claim: claim, root: root, canonicalPath: canonicalPath)
            return RecordingRootOwnership(canonicalPath: canonicalPath, lockFileURL: lockFileURL)
        } catch {
            RecordingRootRegistry.shared.release(canonicalPath)
            throw error
        }
    }

    /// Creates the root directory and lands `claim`'s lock marker in it,
    /// taking over a stale marker (dead owner pid, this process's own
    /// leftover pid, or an undecodable payload) with a logged warning.
    ///
    /// - Parameters:
    ///   - claim: The owner record to write as the marker's payload.
    ///   - root: The recording root the marker guards.
    ///   - canonicalPath: `root`'s canonical path, which the marker's URL is
    ///     built from so it matches the registry's key.
    /// - Returns: The created marker's URL.
    /// - Throws: ``RecordingRootLockError`` when a live owner holds the
    ///   marker or a takeover race is lost; otherwise any file-system error.
    private static func writeMarker(
        claim: RecordingRootOwner,
        root: URL,
        canonicalPath: String
    ) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockFileURL = URL(fileURLWithPath: canonicalPath, isDirectory: true)
            .appendingPathComponent(recordingRootLockFileName, isDirectory: false)
        if try createMarkerExclusively(at: lockFileURL, claim: claim) {
            return lockFileURL
        }
        if let existing = readMarker(at: lockFileURL),
            existing.processId != claim.processId,
            isProcessAlive(existing.processId) {
            throw RecordingRootLockError.alreadyOwned(root: root, owner: existing)
        }
        lockLogger.warning(
            "taking over stale recording-root lock at \(lockFileURL.path, privacy: .public)"
        )
        try FileManager.default.removeItem(at: lockFileURL)
        guard try createMarkerExclusively(at: lockFileURL, claim: claim) else {
            throw RecordingRootLockError.contested(root: root)
        }
        return lockFileURL
    }

    /// Atomically creates the marker file with `claim`'s JSON payload, using
    /// `O_CREAT | O_EXCL` so exactly one writer — across processes — can win.
    ///
    /// - Parameters:
    ///   - url: The marker file to create.
    ///   - claim: The owner record to write as its payload.
    /// - Returns: `true` when this call created the marker; `false` when the
    ///   marker already exists.
    /// - Throws: Any encoding or file-system error other than "already exists".
    private static func createMarkerExclusively(at url: URL, claim: RecordingRootOwner) throws -> Bool {
        let payload = try JSONEncoder().encode(claim)
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, lockFileMode)
        if descriptor < 0 {
            if errno == EEXIST { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: payload)
        return true
    }

    /// Decodes the owner record from the marker at `url`.
    ///
    /// - Parameter url: The marker file to read.
    /// - Returns: The recorded owner, or `nil` when the file is unreadable or
    ///   its payload does not decode — a torn marker, which is stale.
    private static func readMarker(at url: URL) -> RecordingRootOwner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingRootOwner.self, from: data)
    }

    /// Whether the process with `processId` is currently running, probed with
    /// the null signal (`kill(pid, 0)`); a live-but-unsignalable process
    /// (`EPERM`) counts as running.
    ///
    /// - Parameter processId: The process id to probe.
    /// - Returns: `true` when the process runs.
    private static func isProcessAlive(_ processId: Int32) -> Bool {
        guard processId > 0 else { return false }
        if kill(processId, 0) == 0 { return true }
        return errno == EPERM
    }
}
