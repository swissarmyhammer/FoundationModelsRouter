import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
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
/// each fork through the request with its own tool surface, records each
/// call, and keeps each request. It refuses each start and each restore
/// (``StartRefusingLauncher``): the fork tests start no root session and
/// restore no session through it.
final class ForkLaunchingLauncher: StartRefusingLauncher {
    /// What the launcher does for a fork.
    enum Behavior {
        /// Builds the fork with the tools, and returns it.
        case build
        /// Throws ``Refusal`` before it builds the fork.
        case throwBeforeBuild
        /// Builds the fork, and then throws ``Refusal``.
        case buildThenThrow
        /// Builds the fork two times.
        case buildTwice
        /// Builds the fork, and returns the session that the test gives.
        case returnOther(any RoutedSession)
    }

    /// The error of a launcher that refuses a fork.
    struct Refusal: Error, Equatable {}

    /// What the launcher records.
    private struct State {
        /// Each fork call, in order.
        var launches: [ForkLaunch] = []

        /// The request of each fork call, in order. The launcher keeps them
        /// after the call ends, as a host that breaks the contract can.
        var requests: [SessionLaunchForkRequest] = []

        /// Each fork that the launcher built, in order.
        var sessions: [any RoutedSession] = []

        /// The state of each fork when the launcher returned it, in order.
        var statesAtReturn: [ForkStateAtReturn] = []
    }

    /// The tools that the launcher gives to each fork.
    private let surface: [any Tool]

    /// The added folders that the launcher gives to each fork, or `nil` for
    /// a launcher that gives only tools
    /// (``SessionLaunchForkRequest/makeFork(tools:)``).
    private let additionalDirectories: [URL]?

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
    ///   - additionalDirectories: The added folders of each fork, or `nil`
    ///     for a launcher that gives only tools. The default is `nil`.
    init(
        behavior: Behavior = .build, surface: [any Tool] = [HostSurfaceTool()], additionalDirectories: [URL]? = nil
    ) {
        self.behavior = behavior
        self.surface = surface
        self.additionalDirectories = additionalDirectories
    }

    /// Each fork call, in order.
    var launches: [ForkLaunch] {
        state.withLock { $0.launches }
    }

    /// The request of each fork call, in order.
    var requests: [SessionLaunchForkRequest] {
        state.withLock { $0.requests }
    }

    /// Each fork that the launcher built, in order.
    var sessions: [any RoutedSession] {
        state.withLock { $0.sessions }
    }

    /// The state of each fork when the launcher returned it, in order.
    var statesAtReturn: [ForkStateAtReturn] {
        state.withLock { $0.statesAtReturn }
    }

    /// Records and keeps `request`, builds the fork with ``surface``, and
    /// acts as ``behavior`` says.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork, or the session of ``Behavior/returnOther(_:)``.
    /// - Throws: ``Refusal`` for ``Behavior/throwBeforeBuild`` and
    ///   ``Behavior/buildThenThrow``, or the error of a build.
    func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        state.withLock { state in
            state.launches.append(ForkLaunch(request))
            state.requests.append(request)
        }
        switch behavior {
        case .build:
            let fork = try await build(request)
            await recordStateAtReturn(of: fork)
            return fork
        case .throwBeforeBuild:
            throw Refusal()
        case .buildThenThrow:
            _ = try await build(request)
            throw Refusal()
        case .buildTwice:
            _ = try await build(request)
            return try await request.makeFork(tools: surface)
        case .returnOther(let other):
            _ = try await build(request)
            return other
        }
    }

    /// Builds the fork of `request` with ``surface``, and with
    /// ``additionalDirectories`` when the launcher has them, and keeps it.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork.
    /// - Throws: The error of the build.
    private func build(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        let fork =
            if let additionalDirectories {
                try await request.makeFork(tools: surface, additionalDirectories: additionalDirectories)
            } else {
                try await request.makeFork(tools: surface)
            }
        state.withLock { $0.sessions.append(fork) }
        return fork
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

/// The mark that a test sets around its own call of
/// ``RouterSessionDirectory/fork(_:)``, as a host sets a `@TaskLocal` value
/// around its fork call to find its own request in its launcher.
enum ForkCallerMark {
    /// The mark of the caller of the fork, or `nil` when the caller set
    /// none.
    @TaskLocal static var value: String?
}

/// What a ``CallerMarkLauncher`` saw in one fork call.
struct CallerMarkSeen: Equatable {
    /// The id of the fork of the call.
    let forkID: ULID

    /// The ``ForkCallerMark`` that the call saw, or `nil`.
    let mark: String?
}

/// A ``SessionLauncher`` that records the ``ForkCallerMark`` that each fork
/// call sees (D205). Its first fork call waits at a gate after it sends
/// ``firstCallEntered``, until the test sends ``releaseFirstCall``. Thus a
/// test can run a second fork call while the first one waits. It reads the
/// mark after the gate, and builds each fork with no tools.
final class CallerMarkLauncher: StartRefusingLauncher {
    /// What the launcher records.
    private struct State {
        /// The number of fork calls that started.
        var startedCalls = 0

        /// What each fork call saw, in the order of the reads.
        var seen: [CallerMarkSeen] = []
    }

    /// Sent when the first fork call starts.
    let firstCallEntered = AwaitedEvent()

    /// Sent by the test to let the first fork call go on.
    let releaseFirstCall = AwaitedEvent()

    /// The records, which the fork calls change from their tasks.
    private let state = Mutex(State())

    /// What each fork call saw, in the order of the reads.
    var seen: [CallerMarkSeen] {
        state.withLock { $0.seen }
    }

    /// Waits at the gate in the first call, records the mark that the call
    /// sees, and builds the fork with no tools.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork.
    /// - Throws: The error of the wait or of the build.
    func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        let isFirstCall = state.withLock { state in
            state.startedCalls += 1
            return state.startedCalls == 1
        }
        if isFirstCall {
            firstCallEntered.signal()
            try await releaseFirstCall.wait()
        }
        let seen = CallerMarkSeen(forkID: request.forkID, mark: ForkCallerMark.value)
        state.withLock { $0.seen.append(seen) }
        return try await request.makeFork(tools: [])
    }
}
