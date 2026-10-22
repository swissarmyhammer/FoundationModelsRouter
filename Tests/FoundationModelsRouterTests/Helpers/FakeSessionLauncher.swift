import Foundation
import FoundationModelsExtras
import Synchronization

@testable import FoundationModelsRouter

/// A ``SessionLauncher`` for the tests of ``RouterSessionDirectory/start(_:)``
/// (ROUTER-8) and of the delivery to a recorded session (ROUTER-5): it
/// records each request and each restore it gets, vends each session from
/// the `.standard` slot of one scripted profile, and restores each recorded
/// session through that slot.
///
/// It keeps each session it vends or restores. The directory holds a session
/// weakly, so the launcher holds the strong reference, as a host does.
final class FakeSessionLauncher: SessionLauncher {
    /// What the launcher records.
    private struct State {
        /// Each request, in the order the launcher got them.
        var requests: [SessionStartRequest] = []

        /// The id of each restore, in the order the launcher got them.
        var restoredIDs: [ULID] = []

        /// Each session the launcher vended or restored, in order.
        var sessions: [any RoutedSession] = []
    }

    /// The scripted profile the sessions come from.
    private let profile: LanguageModelProfile

    /// `true` when the launcher keeps the launcher contract and copies the
    /// facts of each request into the configuration it vends with; `false`
    /// for a launcher that breaks the contract and vends with none of them.
    private let copiesRequestFacts: Bool

    /// The error each restore throws, or `nil` for a launcher whose restores
    /// succeed.
    private let restoreError: (any Error)?

    /// The requests, the restores and the sessions, which the directory
    /// changes from its task.
    private let state = Mutex(State())

    /// Makes a launcher over a scripted profile.
    ///
    /// - Parameters:
    ///   - profile: The profile the sessions come from.
    ///   - copiesRequestFacts: `true` (the default) to copy the facts of each
    ///     request into the configuration of its session; `false` to vend
    ///     each session with none of them.
    ///   - restoreError: The error each restore throws, or `nil` (the
    ///     default) for restores that succeed.
    init(profile: LanguageModelProfile, copiesRequestFacts: Bool = true, restoreError: (any Error)? = nil) {
        self.profile = profile
        self.copiesRequestFacts = copiesRequestFacts
        self.restoreError = restoreError
    }

    /// Each request the launcher got, in order.
    var requests: [SessionStartRequest] {
        state.withLock { $0.requests }
    }

    /// The id of each restore the launcher got, in order, also of a restore
    /// that threw.
    var restoredIDs: [ULID] {
        state.withLock { $0.restoredIDs }
    }

    /// Each session the launcher vended or restored, in order.
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

    /// Records the restore of `id`, and restores the recorded session `id`
    /// through the `.standard` slot of the profile.
    ///
    /// - Parameter id: The session id.
    /// - Returns: The restored session.
    /// - Throws: The `restoreError` of the launcher, or the error of the
    ///   restore.
    func restoreSession(id: ULID) async throws -> any RoutedSession {
        state.withLock { $0.restoredIDs.append(id) }
        if let restoreError {
            throw restoreError
        }
        let session = try await profile.standard.restoreSession(id: id).session
        state.withLock { $0.sessions.append(session) }
        return session
    }

    /// Closes each session the launcher vended or restored.
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
