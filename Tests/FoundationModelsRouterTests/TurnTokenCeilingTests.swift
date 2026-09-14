import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// The token ceiling of a turn comes from the context of the resolved model,
/// and not from a constant.
///
/// A routed session knows the working context its profile resolved to. A turn
/// that names no `maxTokens` generates under that context. A turn that names
/// one keeps it. The live backend keeps a named floor only for a caller that
/// gives it no ceiling at all.
@Suite("Turn token ceiling: derived from the resolved context")
struct TurnTokenCeilingTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "TurnTokenCeilingTests"

    /// A resolved working context that is not the default context, so a test
    /// cannot pass on a fallback that happens to equal it.
    private static let resolvedContext = 32_768

    /// An explicit ceiling a caller names, smaller than any context here.
    private static let requestedCeiling = 256

    @Test("a respond turn that names no ceiling generates under the resolved context")
    func respondUsesResolvedContext() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.resolvedContext, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let _: String = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        #expect(fixture.log.requestedCeilings == [Self.resolvedContext])
    }

    @Test("a streamed turn that names no ceiling generates under the resolved context")
    func streamUsesResolvedContext() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.resolvedContext, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let _: TurnOutcome = try await fixture.session.respond(to: "fix the bug", maxTokens: nil)

        #expect(fixture.log.requestedCeilings == [Self.resolvedContext])
    }

    @Test("a turn that names a ceiling keeps that ceiling")
    func explicitCeilingIsKept() async throws {
        let fixture = try await CeilingProbeSessionFixture.make(
            ending: .finished, context: Self.resolvedContext, tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let _: String = try await fixture.session.respond(to: "fix the bug", maxTokens: Self.requestedCeiling)

        #expect(fixture.log.requestedCeilings == [Self.requestedCeiling])
    }

    @Test("a session whose context is unknown leaves the ceiling to the backend")
    func unknownContextGivesNoCeiling() {
        #expect(RoutedSessionActor.responseTokenCeiling(requested: nil, contextTokens: 0) == nil)
    }

    @Test("the live backend generates under its named floor when the caller gives no ceiling")
    func liveBackendFallsBackToFloor() async throws {
        let log = CeilingProbeLog()
        let container = CeilingProbeContainer(model: CeilingProbeLanguageModel(ending: .finished, log: log))
        let backend = container.makeSession(instructions: nil)

        _ = try await backend.respond(to: "fix the bug", maxTokens: nil)

        #expect(log.requestedCeilings == [MLXFoundationModelsSessionBackend.responseTokenFloor])
    }
}
