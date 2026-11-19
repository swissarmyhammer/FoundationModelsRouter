import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization

/// The fork that ``RouterSessionDirectory/fork(_:)`` asks the launcher to
/// build (D205): ``SessionLauncher/forkSession(_:)`` gets it.
///
/// The directory makes the request after it mapped the cut of the fork to a
/// position in the history of the source (``ForkCutHistory``), and after it
/// chose the id of the fork. The launcher does not map the cut again: it
/// builds the fork through the request, with ``makeFork(tools:)`` for the
/// tools of the host or ``makeFork()`` for the tools of the source. The
/// fork that the request builds has ``forkID`` as its id, ``sourceID`` as its
/// parent, and ``forkedAtHistoryOrdinal`` in its record
/// (``SessionRecord/forkedAtHistoryOrdinal``). It records as a fork node in
/// the recording folder of the source.
///
/// A request builds one fork. The launcher returns that fork, and the
/// directory refuses each other session
/// (``SessionLaunchForkError/notTheRequestedFork(_:)``).
public struct SessionLaunchForkRequest: Sendable {
    /// The id of the source of the fork.
    public let sourceID: ULID

    /// The id of the fork, which the directory chose. The fork that the
    /// request builds has this id.
    public let forkID: ULID

    /// The cut of the fork: the position in the recorded history of the
    /// source where the history of the fork stops. The record of the fork
    /// holds it as ``SessionRecord/forkedAtHistoryOrdinal``.
    public let forkedAtHistoryOrdinal: Int

    /// The working folder of the fork: the working folder of the source.
    public let workingDirectory: URL

    /// The UI client that asked for the fork, or `nil` for a fork that a
    /// session asked for.
    public let requestedByClient: String?

    /// The build of the fork, which all copies of this request share.
    let build: ForkBuild

    /// Makes the request of a fork of `source` from `seed`.
    ///
    /// - Parameters:
    ///   - source: The source of the fork.
    ///   - seed: The transcript, the cut and the context counter of the
    ///     fork.
    ///   - forkID: The id of the fork.
    ///   - requestedByClient: The UI client that asked for the fork, or
    ///     `nil`.
    init(source: RoutedSessionActor, seed: ForkSeed, forkID: ULID, requestedByClient: String?) {
        self.sourceID = source.id
        self.forkID = forkID
        self.forkedAtHistoryOrdinal = seed.historyOrdinal
        self.workingDirectory = source.workingDirectory
        self.requestedByClient = requestedByClient
        self.build = ForkBuild(source: source, seed: seed, forkID: forkID)
    }

    /// Builds the fork with `tools`: the tool surface that the host gives
    /// the fork, in place of the tools of the source. Each other setting of
    /// the fork comes from the source.
    ///
    /// - Parameter tools: The tools of the fork.
    /// - Returns: The fork, not registered.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when this
    ///   request built its fork before.
    public func makeFork(tools: [any Tool]) async throws -> any RoutedSession {
        try await build.make(tools: tools)
    }

    /// Builds the fork with the tools of the source, each forked first
    /// (`ForkableTool.forked()`, or the tool itself). This is the fork of a
    /// launcher that does not implement ``SessionLauncher/forkSession(_:)``.
    ///
    /// - Returns: The fork, not registered.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when this
    ///   request built its fork before.
    public func makeFork() async throws -> any RoutedSession {
        try await build.make(tools: nil)
    }
}

/// The errors of a fork that a launcher builds (D205).
public enum SessionLaunchForkError: Error, Sendable, Equatable {
    /// The request built its fork before. A request builds one fork.
    case forkAlreadyMade(ULID)

    /// The launcher returned a session that is not the fork that the request
    /// built.
    case notTheRequestedFork(ULID)
}

/// The one build of the fork of a ``SessionLaunchForkRequest``: it builds the
/// fork one time, keeps it, and removes it again when the directory refuses
/// the fork.
final class ForkBuild: Sendable {
    /// The state of the build.
    private enum State {
        /// No build started.
        case open

        /// A build runs.
        case building

        /// The fork that the build made.
        case built(RoutedSessionActor)
    }

    /// The source of the fork.
    private let source: RoutedSessionActor

    /// The transcript, the cut and the context counter of the fork.
    private let seed: ForkSeed

    /// The id of the fork.
    private let forkID: ULID

    /// The state of the build.
    private let state = Mutex(State.open)

    /// Makes the build of a fork.
    ///
    /// - Parameters:
    ///   - source: The source of the fork.
    ///   - seed: The seed of the fork.
    ///   - forkID: The id of the fork.
    init(source: RoutedSessionActor, seed: ForkSeed, forkID: ULID) {
        self.source = source
        self.seed = seed
        self.forkID = forkID
    }

    /// The folder where the fork records: a folder in the recording folder
    /// of the source.
    var recordingDirectory: URL {
        source.recordingDirectory.appendingPathComponent(forkID.description, isDirectory: true)
    }

    /// The fork that the build made, or `nil` before it made one.
    var fork: RoutedSessionActor? {
        state.withLock { state in
            guard case .built(let fork) = state else { return nil }
            return fork
        }
    }

    /// Removes the fork of a refused build: closes the fork that the build
    /// made, and removes its recording node. A build that made no fork
    /// removes nothing.
    ///
    /// - Throws: The error of the removal of the recording node.
    func discard() async throws {
        guard let fork else { return }
        await fork.close()
        try FileManager.default.removeItem(at: recordingDirectory)
    }

    /// Builds the fork with `tools`, or with the tools of the source for
    /// `nil`. A build that throws made no fork, so the build is open again.
    ///
    /// - Parameter tools: The tools of the fork, or `nil`.
    /// - Returns: The fork.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when a build
    ///   runs or made the fork before, or the error of the build.
    func make(tools: [any Tool]?) async throws -> RoutedSessionActor {
        try state.withLock { state in
            guard case .open = state else { throw SessionLaunchForkError.forkAlreadyMade(forkID) }
            state = .building
        }
        do {
            let fork = try await source.makeFork(id: forkID, seed: seed, tools: tools)
            state.withLock { $0 = .built(fork) }
            return fork
        } catch {
            state.withLock { $0 = .open }
            throw error
        }
    }
}
