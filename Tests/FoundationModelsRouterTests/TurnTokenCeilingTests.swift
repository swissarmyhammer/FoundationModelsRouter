import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The token ceiling of a turn comes from the context of the resolved model,
/// and not from a constant.
///
/// A routed session knows the working context its profile resolved to. A turn
/// that names no `maxTokens` generates under that context. A turn that names
/// one keeps it. A caller that gives the live backend no ceiling at all makes
/// it request the window of its model, so the default ceiling of the engine
/// never applies.
///
/// Each rule is proven on the respond path and on each stream path, because
/// each path gives the backend its ceiling through a different call.
@Suite("Turn token ceiling: derived from the resolved context")
struct TurnTokenCeilingTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "TurnTokenCeilingTests"

    /// A resolved working context that is not `ScriptedSessionContext.tokens`,
    /// the window most fixtures state, so a test cannot pass on a fixture
    /// window that happens to equal it.
    private static let resolvedContext = 32_768

    /// An explicit ceiling a caller names, smaller than any context here.
    private static let requestedCeiling = 256

    /// The prompt each turn of this suite sends.
    private static let prompt = "fix the bug"

    /// A public surface of ``RoutedSession`` that runs one turn.
    enum SessionSurface: CaseIterable, Sendable {
        /// ``RoutedSession/respond(to:maxTokens:)``.
        case respond

        /// ``RoutedSession/streamResponse(to:maxTokens:)``.
        case streamResponse

        /// ``RoutedSession/streamEvents(to:maxTokens:)``.
        case streamEvents

        /// Runs one turn on `session` through this surface, and consumes the
        /// whole stream of a stream surface.
        ///
        /// - Parameters:
        ///   - session: The session to run the turn on.
        ///   - maxTokens: The ceiling the turn names, or `nil`.
        /// - Throws: Whatever the turn throws.
        func runTurn(on session: RoutedSession, maxTokens: Int?) async throws {
            switch self {
            case .respond:
                let _: String = try await session.respond(to: TurnTokenCeilingTests.prompt, maxTokens: maxTokens)
            case .streamResponse:
                for try await _ in await session.streamResponse(to: TurnTokenCeilingTests.prompt, maxTokens: maxTokens) {}
            case .streamEvents:
                for try await _ in await session.streamEvents(to: TurnTokenCeilingTests.prompt, maxTokens: maxTokens) {}
            }
        }
    }

    /// A generation surface of ``MLXFoundationModelsSessionBackend``.
    enum BackendSurface: CaseIterable, Sendable {
        /// ``MLXFoundationModelsSessionBackend/respond(to:maxTokens:)``.
        case respond

        /// ``MLXFoundationModelsSessionBackend/streamResponse(to:maxTokens:)``.
        case streamResponse

        /// Runs one generation call on `backend` through this surface, and
        /// consumes the whole stream of the stream surface.
        ///
        /// - Parameters:
        ///   - backend: The backend to run the call on.
        ///   - maxTokens: The ceiling the call names, or `nil`.
        /// - Throws: Whatever the call throws.
        func runCall(on backend: any LanguageModelSessionBackend, maxTokens: Int?) async throws {
            switch self {
            case .respond:
                _ = try await backend.respond(to: TurnTokenCeilingTests.prompt, maxTokens: maxTokens)
            case .streamResponse:
                for try await _ in backend.streamResponse(to: TurnTokenCeilingTests.prompt, maxTokens: maxTokens) {}
            }
        }
    }

    @Test(
        "a turn that names no ceiling generates under the resolved context",
        arguments: SessionSurface.allCases)
    func turnUsesResolvedContext(surface: SessionSurface) async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.resolvedContext, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await surface.runTurn(on: fixture.session, maxTokens: nil)

        #expect(fixture.log.requestedCeilings == [Self.resolvedContext])
    }

    @Test("a turn that names a ceiling keeps that ceiling", arguments: SessionSurface.allCases)
    func explicitCeilingIsKept(surface: SessionSurface) async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.resolvedContext, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        try await surface.runTurn(on: fixture.session, maxTokens: Self.requestedCeiling)

        #expect(fixture.log.requestedCeilings == [Self.requestedCeiling])
    }

    @Test("a session whose context is unknown leaves the ceiling to the backend")
    func unknownContextGivesNoCeiling() {
        #expect(RoutedSessionActor.responseTokenCeiling(requested: nil, contextTokens: 0) == nil)
    }

    @Test(
        "the live backend requests the window of its model when the caller gives no ceiling",
        arguments: BackendSurface.allCases)
    func liveBackendRequestsModelWindow(surface: BackendSurface) async throws {
        let log = CeilingProbeLog()
        let container = LiveBackendContainer(
            model: CeilingProbeLanguageModel(ending: .finished, log: log), contextWindow: Self.resolvedContext)
        let backend = container.makeSession(instructions: nil)

        try await surface.runCall(on: backend, maxTokens: nil)

        #expect(log.requestedCeilings == [Self.resolvedContext])
    }

    @Test(
        "the live backend requests the ceiling the caller gives",
        arguments: BackendSurface.allCases)
    func liveBackendKeepsGivenCeiling(surface: BackendSurface) async throws {
        let log = CeilingProbeLog()
        let container = LiveBackendContainer(
            model: CeilingProbeLanguageModel(ending: .finished, log: log), contextWindow: Self.resolvedContext)
        let backend = container.makeSession(instructions: nil)

        try await surface.runCall(on: backend, maxTokens: Self.requestedCeiling)

        #expect(log.requestedCeilings == [Self.requestedCeiling])
    }
}
