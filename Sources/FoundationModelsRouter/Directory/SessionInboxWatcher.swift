import Dispatch
import Foundation
import Synchronization

/// The number of ``SessionInboxWatcher`` values that are open: made, and not
/// cancelled yet. One directory owns one counter and gives it to each watcher
/// it makes. Only a test reads the count, to find a watcher that nothing
/// cancelled.
final class SessionInboxWatcherCount: Sendable {
    /// The open watchers.
    private let watchers = Mutex(0)

    /// The number of watchers that are open now.
    var current: Int {
        watchers.withLock { $0 }
    }

    /// Adds one open watcher.
    func opened() {
        watchers.withLock { $0 += 1 }
    }

    /// Removes one open watcher.
    func closed() {
        watchers.withLock { $0 -= 1 }
    }
}

/// A watcher of the `inbox/` folder of one durable session folder: a
/// `DispatchSource` on the vnode of the folder that reports each write, which
/// is each file that arrives or leaves.
///
/// The watcher only tells its owner that the folder changed. It does not read
/// the folder. An event can stand for more than one change, because events
/// merge, so the owner scans the full folder on each call and never one file
/// for each event. The first call is not an event: a file can arrive while no
/// process owns the session, so ``start()`` calls the owner once after the
/// source runs.
///
/// Only the process that owns the recording root delivers the files. That
/// process is the only one whose directory registers sessions, and so the
/// only one that makes a watcher.
///
/// The event handler holds the closure of the owner and the file
/// descriptor, never the watcher, so the watcher can end by the release of
/// its last reference. ``cancel()`` ends the watcher at once, and it is safe
/// to call more than once and before ``start()``.
final class SessionInboxWatcher: Sendable {
    /// The queue that runs the event handlers. A handler does no work but the
    /// call of the closure of the owner, so all watchers share one queue.
    private static let queue = DispatchQueue(label: "FoundationModelsRouter.SessionInboxWatcher")

    /// What the watcher holds under its lock.
    private struct Phase {
        /// The file descriptor of the `inbox/` folder. The cancel handler of
        /// the source closes it, or ``cancel()`` closes it when the source
        /// never ran.
        let descriptor: Int32

        /// The source, or `nil` before ``start()``.
        var source: (any DispatchSourceFileSystemObject)?

        /// Whether ``cancel()`` ran.
        var isCancelled = false
    }

    /// The state that ``start()`` and ``cancel()`` change.
    private let phase: Mutex<Phase>

    /// The counter of open watchers of the owner.
    private let count: SessionInboxWatcherCount

    /// What the owner does when the folder changed.
    private let onChange: @Sendable () -> Void

    /// Opens the `inbox/` folder of a session folder for watching. The folder
    /// is made when it is absent. The source does not run until ``start()``.
    ///
    /// - Parameters:
    ///   - sessionFolder: The session folder.
    ///   - count: The counter of open watchers. The watcher is in it from
    ///     here until ``cancel()``.
    ///   - onChange: What to do on each change of the folder, and once at
    ///     ``start()``. The closure holds its owner weakly.
    /// - Throws: The error of the folder make, or the POSIX error of the open.
    init(sessionFolder: URL, count: SessionInboxWatcherCount, onChange: @escaping @Sendable () -> Void) throws {
        let inbox = SessionInboxFile.directory(in: sessionFolder)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let descriptor = open(inbox.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.phase = Mutex(Phase(descriptor: descriptor))
        self.count = count
        self.onChange = onChange
        count.opened()
    }

    deinit {
        cancel()
    }

    /// Runs the source, and then calls the closure of the owner once, for
    /// the files that came before the watcher. A watcher that is cancelled
    /// already does nothing.
    func start() {
        let started = phase.withLock { held -> Bool in
            guard !held.isCancelled, held.source == nil else { return false }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: held.descriptor, eventMask: .write, queue: Self.queue)
            let onChange = onChange
            let descriptor = held.descriptor
            source.setEventHandler { onChange() }
            source.setCancelHandler { close(descriptor) }
            held.source = source
            source.resume()
            return true
        }
        if started {
            onChange()
        }
    }

    /// Ends the watcher: the source stops, the file descriptor closes, and
    /// the watcher leaves the count. After this call no event reaches the
    /// owner. A second call changes nothing.
    func cancel() {
        let cancelled = phase.withLock { held -> Bool in
            guard !held.isCancelled else { return false }
            held.isCancelled = true
            if let source = held.source {
                source.cancel()
            } else {
                close(held.descriptor)
            }
            return true
        }
        if cancelled {
            count.closed()
        }
    }
}
