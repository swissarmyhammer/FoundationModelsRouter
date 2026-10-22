import Foundation
import FoundationModelsExtras
import Synchronization

@testable import FoundationModelsRouter

/// A ``SessionLauncher`` for the tests of ``RouterSessionDirectory/start(_:)``
/// (ROUTER-8): it records each request it gets, and vends each session from
/// the `.standard` slot of one scripted profile.
///
/// It keeps each session it vends. The directory holds a session weakly, so
/// the launcher holds the strong reference, as a host does.
final class FakeSessionLauncher: SessionLauncher {
    /// What the launcher records.
    private struct State {
        /// Each request, in the order the launcher got them.
        var requests: [SessionStartRequest] = []

        /// Each session the launcher vended, in order.
        var sessions: [any RoutedSession] = []
    }

    /// The scripted profile the sessions come from.
    private let profile: LanguageModelProfile

    /// `true` when the launcher keeps the launcher contract and copies the
    /// facts of each request into the configuration it vends with; `false`
    /// for a launcher that breaks the contract and vends with none of them.
    private let copiesRequestFacts: Bool

    /// The requests and the sessions, which `start` changes from its task.
    private let state = Mutex(State())

    /// Makes a launcher over a scripted profile.
    ///
    /// - Parameters:
    ///   - profile: The profile the sessions come from.
    ///   - copiesRequestFacts: `true` (the default) to copy the facts of each
    ///     request into the configuration of its session; `false` to vend
    ///     each session with none of them.
    init(profile: LanguageModelProfile, copiesRequestFacts: Bool = true) {
        self.profile = profile
        self.copiesRequestFacts = copiesRequestFacts
    }

    /// Each request the launcher got, in order.
    var requests: [SessionStartRequest] {
        state.withLock { $0.requests }
    }

    /// Each session the launcher vended, in order.
    var sessions: [any RoutedSession] {
        state.withLock { $0.sessions }
    }

    /// Records `request` and vends one session for it.
    ///
    /// - Parameter request: The start request, as the directory gives it.
    /// - Returns: The vended session.
    func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
        let session = profile.standard.makeSession(configuration: configuration(for: request))
        state.withLock { state in
            state.requests.append(request)
            state.sessions.append(session)
        }
        return session
    }

    /// The fake restores nothing.
    ///
    /// - Parameter id: The session id.
    /// - Returns: Nothing.
    /// - Throws: `SessionDirectoryError.unknownSession(id)`.
    func restoreSession(id: ULID) async throws -> any RoutedSession {
        throw SessionDirectoryError.unknownSession(id)
    }

    /// Closes each session the launcher vended.
    func closeSessions() async {
        for session in sessions {
            await session.close()
        }
    }

    /// The configuration the launcher vends the session of `request` with.
    ///
    /// - Parameter request: The start request.
    /// - Returns: The facts of `request` when the launcher keeps the
    ///   contract, else the empty configuration.
    private func configuration(for request: SessionStartRequest) -> SessionConfiguration {
        guard copiesRequestFacts else { return SessionConfiguration() }
        return SessionConfiguration(
            workingDirectory: request.workingDirectory, agentID: request.agentID, tags: request.tags,
            title: request.title, startedBy: request.startedBy, origin: request.origin,
            requestedByClient: request.requestedByClient)
    }
}
