import Foundation
import Testing

import FoundationModelsRouter

/// Holds the dynamic-JSON guided surface — `respond(to:matching:)`, the
/// ``JSONValue`` it returns, and the ``GuidedRequestError`` it throws — to the
/// access level a consumer outside this module needs (task ^jp93e7c).
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: a member that loses `public`, or an error type that goes back
/// to `internal`, stops this file from compiling before a single test runs. The
/// two bodies then drive that surface end to end over the scripted stub model,
/// so the suite measures behavior as well as reach.
@Suite("Guided dynamic-JSON members over the public surface")
struct GuidedPublicSurfaceTests {
    /// The temp-directory prefix every fixture in this suite is built with, so
    /// a leaked directory is attributable to this suite.
    private static let tempDirPrefix = "GuidedPublicSurfaceTests"

    /// The prompt every turn in this suite is driven with. The scripted model
    /// reads no prompt, so one string serves every case.
    private static let prompt = "hi"

    /// A runtime JSON Schema inside the xgrammar-supported subset — one object
    /// with one required string property.
    private static let objectSchema = """
        {"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
        """

    /// The canned constrained output the scripted model answers with: a
    /// schema-valid instance of ``objectSchema``.
    private static let cannedObject = "{\"name\":\"ok\"}"

    /// The ``JSONValue`` ``cannedObject`` parses into.
    private static let parsedCannedObject: JSONValue = .object(["name": .string("ok")])

    /// A runtime JSON Schema outside the xgrammar-supported subset, so the
    /// guided call is rejected before any decode is attempted.
    private static let overSpecSchema = "{\"$ref\":\"#/$defs/Y\"}"

    /// The one unsupported keyword ``overSpecSchema`` uses, which the rejection
    /// names.
    private static let unsupportedKeyword = "$ref"

    /// Resolves a profile over a scripted model answering with ``cannedObject``.
    ///
    /// The scripted backend runs the real (GPU-free) xgrammar-subset validation
    /// behind its guided entry point, so a rejected schema raises the same error
    /// a live model would.
    ///
    /// The whole profile comes back, not the `.standard` handle alone: a handle
    /// holds its owning profile weakly, and a call on a handle whose profile was
    /// already released traps.
    ///
    /// - Returns: The resolved profile and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile() async throws -> (profile: LanguageModelProfile, directory: URL) {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: ConfiguredLLMContainer(responseText: cannedObject),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile, directory)
    }

    // MARK: - respond(to:matching:)

    @Test("respond(to:matching:) answers a consumer outside the module with a JSONValue")
    @MainActor
    func respondMatchingReturnsAJSONValue() async throws {
        let (profile, directory) = try await Self.makeProfile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let value = try await profile.standard.respond(to: Self.prompt, matching: Self.objectSchema)

        #expect(value == Self.parsedCannedObject)
    }

    // MARK: - GuidedRequestError

    @Test("a rejected schema throws a GuidedRequestError a consumer catches by type")
    @MainActor
    func respondMatchingThrowsANameableGuidedRequestError() async throws {
        let (profile, directory) = try await Self.makeProfile()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try await profile.standard.respond(to: Self.prompt, matching: Self.overSpecSchema)
            Issue.record("respond(to:matching:) accepted a schema outside the supported subset")
        } catch let error as GuidedRequestError {
            // Catching by type is the reach the card asks for; naming the case
            // proves the payload reaches a consumer as well.
            #expect(error == .unsupportedSchemaConstructs([Self.unsupportedKeyword]))
        }
    }
}
