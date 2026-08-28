import Foundation
import FoundationModels
import Tracing

@testable import FoundationModelsRouter

/// A `RoutedSession` vended over a scripted model, together with everything a
/// test needs to read the turn back and to clean up after it.
///
/// Built the way a host builds one — a ``Router`` over stubbed hardware, a
/// resolved profile, then `makeSession(tools:)` off the profile's standard slot
/// — so a turn driven through it crosses Router's real session machinery, with
/// the scripted model standing in only for the weights.
struct ScriptedSessionFixture {
    /// The vended session a test drives its turn on.
    let session: RoutedSession

    /// The log the scripted model writes its observations into.
    let log: ScriptedTurnLog

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// The backends the fixture's container vended, so a test can read the
    /// SDK's own transcript back off the session its turn ran through.
    let vendedBackends: VendedBackendLog

    /// The recorder the fixture's router persists every transcript event
    /// into, so a test can assert on exactly what a turn recorded.
    let recorder: InMemoryRecorder

    /// The resolved profile the session was vended from, retained so a test
    /// can reach the other two slots — the embedding handle above all.
    let profile: LanguageModelProfile

    /// The SDK's own transcript for this fixture's session, in order.
    ///
    /// Read off the vended backend, so it is the same transcript the turn
    /// chokepoint diffed. Only call this once the turn has returned — the
    /// turn-lock discipline ``LanguageModelSessionBackend/transcriptEntries()``
    /// documents.
    ///
    /// - Returns: Every entry the session accumulated, or none when no backend
    ///   was vended.
    func transcriptEntries() -> [Transcript.Entry] {
        vendedBackends.latest?.transcriptEntries() ?? []
    }

    /// Builds a fresh router, resolved profile, and `RoutedSession` over a
    /// ``ScriptedToolCallingContainer`` playing `script`, with `tools` mounted.
    ///
    /// - Parameters:
    ///   - script: The turn shape the scripted model plays out.
    ///   - tools: The tools to mount on the vended session.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    ///   - tracer: The tracer every handle of the resolved profile carries, or
    ///     `nil` (the default) to read `InstrumentationSystem.tracer` at call
    ///     time.
    /// - Returns: The vended session, its scripted model's log, and the temp
    ///   directory the caller must remove.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        playing script: ScriptedTurnScript,
        mounting tools: [any Tool],
        tempDirPrefix: String,
        tracer: (any Tracer)? = nil
    ) async throws -> ScriptedSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = ScriptedTurnLog()
        let recorder = InMemoryRecorder()
        let model = ScriptedToolCallingModel(script: script, log: log)
        let container = ScriptedToolCallingContainer(model: model)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(
                container: container, dimension: RouterTestFixtures.stubDimension),
            tracer: tracer
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return ScriptedSessionFixture(
            session: profile.standard.makeSession(tools: tools),
            log: log,
            directory: directory,
            vendedBackends: container.vendedBackends,
            recorder: recorder,
            profile: profile)
    }
}
