import Foundation
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The logging half of the telemetry vocabulary (``RouterTelemetry``): the
/// label of each logger, the metadata keys, the explicit logger of a session,
/// and the metadata of an error, which names the type and a code and never the
/// description.
@Suite("The router logs through swift-log with the names of its vocabulary")
struct RouterTelemetryLoggingTests {
    /// An error whose description carries text that must not reach a log.
    private struct ContentCarryingError: LocalizedError {
        /// The text of the description.
        let text: String

        var errorDescription: String? { text }
    }

    /// The text that ``ContentCarryingError`` carries in its description.
    private static let content = "the secret prompt text"

    @Test("a logger of the module has the module name and the category as its label")
    func moduleLoggerLabel() {
        let logger = RouterTelemetry.makeLogger(.recording)
        #expect(logger.label == "FoundationModelsRouter.Recording")
    }

    @Test("each log metadata key starts with the module name")
    func metadataKeysStartWithTheModuleName() {
        for key in RouterTelemetry.LogMetadataKey.allKeys {
            #expect(key.hasPrefix("FoundationModelsRouter."), "\(key) has no module prefix")
        }
    }

    @Test("the metadata of an error names its type and code, and never its description")
    func errorMetadataNamesTypeAndCodeOnly() async throws {
        let error = ContentCarryingError(text: Self.content)

        let metadata = RouterTelemetry.errorMetadata(error)

        #expect(metadata[RouterTelemetry.LogMetadataKey.errorType] == "\(ContentCarryingError.self)")
        #expect(metadata[RouterTelemetry.LogMetadataKey.errorCode] == "\((error as NSError).code)")
        try await TelemetryCapture.run(forbidding: [Self.content]) { _ in
            RouterTelemetry.makeLogger(.recording).error("an error happened", metadata: metadata)
        }
    }

    @Test("a module logger made in a capture writes to that capture")
    func moduleLoggerWritesToTheCapture() async throws {
        let logs = try await TelemetryCapture.run(forbidding: []) { context in
            RouterTelemetry.makeLogger(.recording).warning("a warning")
            return context
        }

        logs.expectLogged(containing: "a warning")
    }

    @Test("an explicit logger gets the category as metadata")
    func explicitLoggerGetsTheCategory() async throws {
        let logs = try await TelemetryCapture.run(forbidding: []) { context in
            RouterTelemetry.logger(.generation, explicit: context.logger).warning("a warning")
            return context
        }

        logs.expectLogged(
            containing: "a warning",
            metadata: [RouterTelemetry.LogMetadataKey.category: RouterTelemetry.LogCategory.generation.rawValue])
    }

    /// Makes a session over a stub model in a new temp directory, runs `body`
    /// with it, and then closes the session and removes the directory.
    ///
    /// The close and the removal run also when `body` throws (rule T1). They
    /// run after `body` returns, and each check of a test only looks for a
    /// record that `body` made, so a record of the close changes no check.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `body` runs there.
    ///   - body: The steps of the test, given the session.
    /// - Returns: What `body` returns.
    /// - Throws: What the resolve of the profile or `body` throws.
    private static func withSession<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (any RoutedSession) async throws -> Value
    ) async throws -> Value {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RouterTelemetryLoggingTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir, loader: StubModelLoader(
                container: CannedLLMContainer(ref: "org/std-a"), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        defer { await session.close() }
        return try await body(session)
    }

    @Test("a module logger inside a pump job writes to the explicit logger of the session")
    func pumpJobBindsTheExplicitLogger() async throws {
        let logs = try await Self.withSession { vended in
            let session = try #require(vended as? RoutedSessionActor)
            return try await TelemetryCapture.run(forbidding: []) { context in
                await session.useCaptureLogger(for: context.logger)
                // A detached task gets no capture of its own, as the pump does not,
                // so only the binding of the pump job can bring this record of a
                // module logger to the capture.
                await Task.detached {
                    await session.withSessionLogger {
                        RouterTelemetry.makeLogger(.recording).warning("from a pump job")
                    }
                }.value
                return context
            }
        }

        logs.expectLogged(
            containing: "from a pump job",
            metadata: [RouterTelemetry.LogMetadataKey.category: RouterTelemetry.LogCategory.recording.rawValue])
    }
}
