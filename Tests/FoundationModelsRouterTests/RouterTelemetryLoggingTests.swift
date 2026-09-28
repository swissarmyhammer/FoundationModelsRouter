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

    @Test("a fork starts with the explicit logger of its parent")
    func forkKeepsTheExplicitLogger() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "RouterTelemetryLoggingTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir, loader: StubModelLoader(
                container: CannedLLMContainer(ref: "org/std-a"), dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()

        let logs = try await TelemetryCapture.run(forbidding: []) { context in
            await session.useCaptureLogger(context.logger)
            let child = try #require(try await session.fork(workingDirectory: nil) as? RoutedSessionActor)
            // A detached task gets no capture of its own, so only the explicit
            // logger of the child can bring this record to the capture.
            await Task.detached {
                await child.sessionLogger(.generation).warning("from the child")
            }.value
            return context
        }

        logs.expectLogged(containing: "from the child")
    }
}
