import Foundation
import FoundationModels

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

    /// Builds a fresh router, resolved profile, and `RoutedSession` over a
    /// ``ScriptedToolCallingContainer`` playing `script`, with `tools` mounted.
    ///
    /// - Parameters:
    ///   - script: The turn shape the scripted model plays out.
    ///   - tools: The tools to mount on the vended session.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The vended session, its scripted model's log, and the temp
    ///   directory the caller must remove.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        playing script: ScriptedTurnScript,
        mounting tools: [any Tool],
        tempDirPrefix: String
    ) async throws -> ScriptedSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = ScriptedTurnLog()
        let model = ScriptedToolCallingModel(script: script, log: log)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: ScriptedToolCallingContainer(model: model),
                dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return ScriptedSessionFixture(
            session: profile.standard.makeSession(tools: tools), log: log, directory: directory)
    }
}
