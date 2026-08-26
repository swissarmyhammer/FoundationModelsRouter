import Foundation
import os

/// The logger recording-root ownership reports stale-lock takeovers to.
private let lockLogger = makeModuleLogger(category: "Recording")

/// The lock-marker file name a writer creates inside a recording root it owns.
/// The marker's payload is one JSON-encoded ``RecordingRootOwner``.
let recordingRootLockFileName = "owner.lock"

/// The POSIX permission bits a fresh lock marker is created with.
private let lockFileMode: mode_t = 0o644

/// The writer that holds a recording root: which process took ownership and when.
/// It is the lock marker's payload and the owner named by ``RecordingRootLockError/alreadyOwned(root:owner:)``.
struct RecordingRootOwner: Codable, Equatable, Sendable {
    /// The owning process's id.
    let processId: Int32
    /// When the owner took the root.
    let acquiredAt: Date

    /// Creates an owner record.
    init(processId: Int32, acquiredAt: Date) {
        self.processId = processId
        self.acquiredAt = acquiredAt
    }
}

/// A typed failure taking ownership of a recording root, thrown at open time.
enum RecordingRootLockError: Error, Equatable, LocalizedError {
    /// Another live writer owns the root.
    case alreadyOwned(root: URL, owner: RecordingRootOwner)

    /// A different writer re-created the lock marker during a stale-lock takeover.
    case contested(root: URL)

    /// A localized message describing what error occurred.
    var errorDescription: String? {
        switch self {
        case .alreadyOwned(let root, let owner):
            return
                "recording root \(root.path) is owned by process \(owner.processId) since \(owner.acquiredAt)"
        case .contested(let root):
            return "recording root \(root.path) was claimed by another writer during a stale-lock takeover"
        }
    }
}

/// The process-wide set of recording roots owned by a live
/// ``RecordingRootOwnership`` in this process, keyed by canonical root path.
/// The on-disk marker cannot refuse a second writer in the same process, so this registry does.
private final class RecordingRootRegistry: @unchecked Sendable {
    /// The one registry for the process.
    static let shared = RecordingRootRegistry()

    /// Guards ``owners``. A lock, because release runs synchronously from a `deinit`.
    private let lock = NSLock()

    /// The current in-process owner per canonical root path.
    private var owners: [String: RecordingRootOwner] = [:]

    /// Claims `path` for `owner`.
    /// - Returns: `nil` on success, or the already-registered owner.
    func claim(_ path: String, for owner: RecordingRootOwner) -> RecordingRootOwner? {
        lock.withLock {
            if let existing = owners[path] { return existing }
            owners[path] = owner
            return nil
        }
    }

    /// Releases `path`, which makes it claimable again.
    func release(_ path: String) {
        lock.withLock { _ = owners.removeValue(forKey: path) }
    }
}

/// A held claim on one recording root, which keeps two live writers from
/// appending into the same root. ``acquire(root:)`` claims through an
/// in-process registry and an atomically created on-disk lock marker.
/// A marker with a dead owner is stale and is taken over. `deinit` releases the claim.
final class RecordingRootOwnership: Sendable {
    /// The canonical root path registered in the in-process registry.
    private let canonicalPath: String

    /// The on-disk lock marker this claim created.
    private let lockFileURL: URL

    /// Wraps an already-acquired claim; only ``acquire(root:)`` constructs one.
    private init(canonicalPath: String, lockFileURL: URL) {
        self.canonicalPath = canonicalPath
        self.lockFileURL = lockFileURL
    }

    deinit {
        try? FileManager.default.removeItem(at: lockFileURL)
        RecordingRootRegistry.shared.release(canonicalPath)
    }

    /// Takes ownership of `root` for this process and creates the root directory and its lock marker.
    /// - Returns: The held claim; dropping it releases the root.
    /// - Throws: ``RecordingRootLockError`` when a live writer holds the root or a takeover loses its race.
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

    /// Creates the root directory and lands `claim`'s lock marker in it.
    /// A stale marker (dead owner, this process's own leftover pid, or an undecodable payload) is taken over.
    /// - Returns: The created marker's URL.
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

    /// Atomically creates the marker file with `claim`'s JSON payload, using `O_CREAT | O_EXCL`.
    /// - Returns: `true` when this call created the marker; `false` when the marker already exists.
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
    /// - Returns: The recorded owner, or `nil` when the file is unreadable or its payload does not decode.
    private static func readMarker(at url: URL) -> RecordingRootOwner? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecordingRootOwner.self, from: data)
    }

    /// Whether the process with `processId` is running, probed with `kill(pid, 0)`.
    /// A live-but-unsignalable process (`EPERM`) counts as running.
    private static func isProcessAlive(_ processId: Int32) -> Bool {
        guard processId > 0 else { return false }
        if kill(processId, 0) == 0 { return true }
        return errno == EPERM
    }
}
