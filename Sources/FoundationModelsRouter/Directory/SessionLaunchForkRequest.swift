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
/// builds the fork through the request, with
/// ``makeFork(tools:additionalDirectories:)`` or ``makeFork(tools:)`` for the
/// surface of the host, or ``makeFork()`` for the surface of the source. The
/// fork that the request builds has ``forkID`` as its id, ``sourceID`` as its
/// parent, and ``forkedAtHistoryOrdinal`` in its record
/// (``SessionRecord/forkedAtHistoryOrdinal``). It records as a fork node in
/// the recording folder of the source.
///
/// A request builds one fork. The launcher returns that fork, and the
/// directory refuses each other session
/// (``SessionLaunchForkError/notTheRequestedFork(_:)``).
///
/// A request is usable only in the fork call
/// (``SessionLauncher/forkSession(_:)``). When that call returns or throws,
/// the directory closes the request: a later build throws
/// ``SessionLaunchForkError/requestClosed(_:)``, a build that is in flight
/// at the close discards its fork, and the request releases the source and
/// the tools that it holds.
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
        self.build = ForkBuild(
            forkID: forkID,
            recordingDirectory: source.recordingDirectory.appendingPathComponent(
                forkID.description, isDirectory: true)
        ) { surface in
            try await source.makeFork(id: forkID, seed: seed, surface: surface)
        }
    }

    /// Builds the fork with `tools` and `additionalDirectories`: the surface
    /// that the host gives the fork, in place of the surface of the source.
    /// Each other setting of the fork comes from the source.
    ///
    /// The record of the fork holds `additionalDirectories` as
    /// ``SessionRecord/additionalDirectories``, as the record of a new
    /// session holds the folders that a host added
    /// (``RouterSessionDirectory/setAdditionalDirectories(to:for:)``). The
    /// first `index.md` of the fork has them, so a restore of the fork has
    /// them too.
    ///
    /// - Parameters:
    ///   - tools: The tools of the fork.
    ///   - additionalDirectories: The folders that the host added to the
    ///     working folder of the fork, in the order that the host gives
    ///     them.
    /// - Returns: The fork, not registered.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when this
    ///   request built its fork before;
    ///   ``SessionLaunchForkError/requestClosed(_:)`` when the fork call
    ///   ended before the build started or before it ended.
    public func makeFork(tools: [any Tool], additionalDirectories: [URL]) async throws -> any RoutedSession {
        try await build.make(surface: ForkSurface(tools: tools, additionalDirectories: additionalDirectories))
    }

    /// Builds the fork with `tools` and with no added folders
    /// (``makeFork(tools:additionalDirectories:)``).
    ///
    /// - Parameter tools: The tools of the fork.
    /// - Returns: The fork, not registered.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when this
    ///   request built its fork before;
    ///   ``SessionLaunchForkError/requestClosed(_:)`` when the fork call
    ///   ended before the build started or before it ended.
    public func makeFork(tools: [any Tool]) async throws -> any RoutedSession {
        try await makeFork(tools: tools, additionalDirectories: [])
    }

    /// Builds the fork with the surface of the source: the tools of the
    /// source, each forked first (`ForkableTool.forked()`, or the tool
    /// itself), and the added folders of the source
    /// (``SessionRecord/additionalDirectories``). This is the fork of a
    /// launcher that does not implement ``SessionLauncher/forkSession(_:)``.
    ///
    /// - Returns: The fork, not registered.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when this
    ///   request built its fork before;
    ///   ``SessionLaunchForkError/requestClosed(_:)`` when the fork call
    ///   ended before the build started or before it ended.
    public func makeFork() async throws -> any RoutedSession {
        try await build.make(surface: nil)
    }
}

/// The errors of a fork that a launcher builds (D205).
public enum SessionLaunchForkError: Error, Sendable, Equatable {
    /// The request built its fork before. A request builds one fork.
    case forkAlreadyMade(ULID)

    /// The launcher returned a session that is not the fork that the request
    /// built.
    case notTheRequestedFork(ULID)

    /// The fork call of the request ended, so the request builds no fork.
    case requestClosed(ULID)
}

/// The one build of the fork of a ``SessionLaunchForkRequest``: it builds the
/// fork one time, and keeps it until the fork call of the directory closes
/// the build (``close()``).
///
/// After the close, the build builds no fork: a launcher that kept the
/// request gets ``SessionLaunchForkError/requestClosed(_:)``. A build that
/// is in flight when the close comes discards the fork that it makes. The
/// close releases the builder, and thus the source, the seed and the tools
/// that it holds.
final class ForkBuild: Sendable {
    /// The operation that builds the fork with the surface that it gets, or
    /// with the surface of the source for `nil`.
    typealias Builder = @Sendable (ForkSurface?) async throws -> RoutedSessionActor

    /// The state of the build.
    private enum State {
        /// No build started. The builder holds the source and the seed.
        case open(Builder)

        /// A build runs.
        case building

        /// The fork that the build made.
        case built(RoutedSessionActor)

        /// The fork call ended. The build builds no fork.
        case closed
    }

    /// The id of the fork.
    private let forkID: ULID

    /// The folder where the fork records: a folder in the recording folder
    /// of the source.
    let recordingDirectory: URL

    /// The state of the build.
    private let state: Mutex<State>

    /// Makes the build of a fork.
    ///
    /// - Parameters:
    ///   - forkID: The id of the fork.
    ///   - recordingDirectory: The folder where the fork records.
    ///   - builder: The operation that builds the fork.
    init(forkID: ULID, recordingDirectory: URL, builder: @escaping Builder) {
        self.forkID = forkID
        self.recordingDirectory = recordingDirectory
        self.state = Mutex(.open(builder))
    }

    /// Closes the build: after this call, the build builds no fork, and a
    /// build in flight discards its fork. The fork call of the directory
    /// calls it on each path, when the launcher returns or throws.
    ///
    /// - Returns: The fork that the build made before the close, or `nil`
    ///   when it made none. The caller keeps the fork, or discards it
    ///   (``discard(_:)``).
    func close() -> RoutedSessionActor? {
        state.withLock { state in
            defer { state = .closed }
            guard case .built(let fork) = state else { return nil }
            return fork
        }
    }

    /// Removes a fork of this build that the directory does not keep:
    /// closes `fork`, and removes its recording node.
    ///
    /// - Parameter fork: The fork that this build made.
    /// - Throws: The error of the removal of the recording node.
    func discard(_ fork: RoutedSessionActor) async throws {
        await fork.close()
        try FileManager.default.removeItem(at: recordingDirectory)
    }

    /// Builds the fork with `surface`, or with the surface of the source for
    /// `nil`. A build that throws made no fork, so the build is open again,
    /// unless the build closed meanwhile. A build that ends after the close
    /// discards its fork.
    ///
    /// - Parameter surface: The surface of the fork, or `nil`.
    /// - Returns: The fork.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when a build
    ///   runs or made the fork before;
    ///   ``SessionLaunchForkError/requestClosed(_:)`` when the build closed
    ///   before the build started or before it ended; the error of the
    ///   build; or the error of the removal of the recording node of a fork
    ///   that the build discards.
    func make(surface: ForkSurface?) async throws -> RoutedSessionActor {
        let builder = try startBuild()
        let fork: RoutedSessionActor
        do {
            fork = try await builder(surface)
        } catch {
            state.withLock { state in
                guard case .building = state else { return }
                state = .open(builder)
            }
            throw error
        }
        guard keep(fork) else {
            try await discard(fork)
            throw SessionLaunchForkError.requestClosed(forkID)
        }
        return fork
    }

    /// Moves the build from open to building.
    ///
    /// - Returns: The builder.
    /// - Throws: ``SessionLaunchForkError/forkAlreadyMade(_:)`` when a build
    ///   runs or made the fork before;
    ///   ``SessionLaunchForkError/requestClosed(_:)`` after the close.
    private func startBuild() throws -> Builder {
        try state.withLock { state in
            switch state {
            case .open(let builder):
                state = .building
                return builder
            case .building, .built:
                throw SessionLaunchForkError.forkAlreadyMade(forkID)
            case .closed:
                throw SessionLaunchForkError.requestClosed(forkID)
            }
        }
    }

    /// Keeps `fork` as the fork of the build, when the build did not close
    /// while the fork was built.
    ///
    /// - Parameter fork: The fork that the builder made.
    /// - Returns: `true` when the build keeps `fork`; `false` when the build
    ///   closed, and the caller must discard `fork`.
    private func keep(_ fork: RoutedSessionActor) -> Bool {
        state.withLock { state in
            guard case .building = state else { return false }
            state = .built(fork)
            return true
        }
    }
}
