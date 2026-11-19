import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization

@testable import FoundationModelsRouter

/// A tool of the surface that a host gives to a fork (D205). The scripted
/// model never calls it: the tests read only its name on the fork.
struct HostSurfaceTool: Tool {
    /// The name of the tool.
    static let toolName = "host-surface"

    /// The `Tool` name requirement.
    let name = HostSurfaceTool.toolName

    /// The `Tool` description requirement.
    let description = "test-only tool of the surface of a host"

    /// Gives the name of the tool.
    ///
    /// - Parameter arguments: The arguments of the call. The tool does not
    ///   read them.
    /// - Returns: The name of the tool.
    func call(arguments: AmbientToolArguments) async throws -> String {
        name
    }
}

/// A tool of a source session, for the forks that keep the tools of their
/// source. The scripted model never calls it.
struct SourceSurfaceTool: Tool {
    /// The name of the tool.
    static let toolName = "source-surface"

    /// The `Tool` name requirement.
    let name = SourceSurfaceTool.toolName

    /// The `Tool` description requirement.
    let description = "test-only tool of a source session"

    /// Gives the name of the tool.
    ///
    /// - Parameter arguments: The arguments of the call. The tool does not
    ///   read them.
    /// - Returns: The name of the tool.
    func call(arguments: AmbientToolArguments) async throws -> String {
        name
    }
}

/// What a ``ForkLaunchingLauncher`` got in one fork call.
struct ForkLaunch: Equatable {
    /// The id of the source.
    let sourceID: ULID

    /// The cut, as a position in the history of the source.
    let forkedAtHistoryOrdinal: Int

    /// The id of the fork that the directory chose.
    let forkID: ULID

    /// Copies the fields of `request`.
    ///
    /// - Parameter request: The fork request of the directory.
    init(_ request: SessionLaunchForkRequest) {
        self.init(
            sourceID: request.sourceID, forkedAtHistoryOrdinal: request.forkedAtHistoryOrdinal,
            forkID: request.forkID)
    }

    /// Makes the record of a fork call.
    ///
    /// - Parameters:
    ///   - sourceID: The id of the source.
    ///   - forkedAtHistoryOrdinal: The cut position.
    ///   - forkID: The id of the fork.
    init(sourceID: ULID, forkedAtHistoryOrdinal: Int, forkID: ULID) {
        self.sourceID = sourceID
        self.forkedAtHistoryOrdinal = forkedAtHistoryOrdinal
        self.forkID = forkID
    }
}

/// The state of a fork when the launcher returns it: the prompts of its
/// transcript and the number of messages that wait in its queue.
struct ForkStateAtReturn: Equatable {
    /// The prompt texts of the transcript of the fork.
    let promptTexts: [String]

    /// The number of messages that wait in the queue of the fork.
    let waitingMessages: Int
}

/// A ``SessionLauncher`` that implements the fork operation (D205): it builds
/// each fork through the request with its own tool surface, and records each
/// call. The other operations throw: the fork tests start no root session
/// and restore no session through it.
final class ForkLaunchingLauncher: SessionLauncher {
    /// What the launcher does for a fork.
    enum Behavior {
        /// Builds the fork with the tools, and returns it.
        case build
        /// Builds the fork, and then throws ``Refusal``.
        case buildThenThrow
        /// Builds the fork two times.
        case buildTwice
        /// Builds the fork, and returns the session that the test gives.
        case returnOther(any RoutedSession)
    }

    /// The error of a launcher that refuses a fork, or of an operation that
    /// this launcher does not do.
    struct Refusal: Error, Equatable {}

    /// What the launcher records.
    private struct State {
        /// Each fork call, in order.
        var launches: [ForkLaunch] = []

        /// Each fork that the launcher built, in order.
        var sessions: [any RoutedSession] = []

        /// The state of each fork when the launcher returned it, in order.
        var statesAtReturn: [ForkStateAtReturn] = []
    }

    /// The tools that the launcher gives to each fork.
    private let surface: [any Tool]

    /// What the launcher does for a fork.
    private let behavior: Behavior

    /// The records, which the directory changes from its task.
    private let state = Mutex(State())

    /// Makes a launcher.
    ///
    /// - Parameters:
    ///   - behavior: What the launcher does for a fork. The default builds
    ///     and returns the fork.
    ///   - surface: The tools of each fork. The default is one
    ///     ``HostSurfaceTool``.
    init(behavior: Behavior = .build, surface: [any Tool] = [HostSurfaceTool()]) {
        self.behavior = behavior
        self.surface = surface
    }

    /// Each fork call, in order.
    var launches: [ForkLaunch] {
        state.withLock { $0.launches }
    }

    /// Each fork that the launcher built, in order.
    var sessions: [any RoutedSession] {
        state.withLock { $0.sessions }
    }

    /// The state of each fork when the launcher returned it, in order.
    var statesAtReturn: [ForkStateAtReturn] {
        state.withLock { $0.statesAtReturn }
    }

    /// Throws ``Refusal``: the fork tests start no root session.
    ///
    /// - Parameter request: The start request.
    /// - Returns: Nothing.
    /// - Throws: ``Refusal``.
    func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
        throw Refusal()
    }

    /// Throws ``Refusal``: the fork tests restore no session through this
    /// launcher.
    ///
    /// - Parameter id: The session id.
    /// - Returns: Nothing.
    /// - Throws: ``Refusal``.
    func restoreSession(id: ULID) async throws -> any RoutedSession {
        throw Refusal()
    }

    /// Records `request`, builds the fork with ``surface``, and acts as
    /// ``behavior`` says.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork, or the session of ``Behavior/returnOther(_:)``.
    /// - Throws: ``Refusal`` for ``Behavior/buildThenThrow``, or the error of
    ///   a build.
    func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        state.withLock { $0.launches.append(ForkLaunch(request)) }
        let fork = try await request.makeFork(tools: surface)
        state.withLock { $0.sessions.append(fork) }
        switch behavior {
        case .build:
            await recordStateAtReturn(of: fork)
            return fork
        case .buildThenThrow:
            throw Refusal()
        case .buildTwice:
            return try await request.makeFork(tools: surface)
        case .returnOther(let other):
            return other
        }
    }

    /// Closes each fork that the launcher built.
    func closeSessions() async {
        for session in sessions {
            await session.close()
        }
    }

    /// Records the state of `fork` as the launcher returns it.
    ///
    /// - Parameter fork: The fork that the launcher returns.
    private func recordStateAtReturn(of fork: any RoutedSession) async {
        let state = ForkStateAtReturn(
            promptTexts: await fork.transcript.promptTexts, waitingMessages: await fork.pendingMessages().count)
        self.state.withLock { $0.statesAtReturn.append(state) }
    }
}
