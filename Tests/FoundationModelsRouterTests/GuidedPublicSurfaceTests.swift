import Foundation
import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the router surface a consumer outside this module reaches for to the
/// access level that consumer needs.
///
/// Two halves:
///
/// - The dynamic-JSON guided surface — `respond(to:matching:)`, the
///   ``JSONValue`` it returns, and the ``GuidedRequestError`` it throws
///   (task ^jp93e7c).
/// - The conformance surface of ``LoadedLLMContainer`` and
///   ``LanguageModelSessionBackend``: the members each protocol still requires
///   of an out-of-module conformer, once the defaults it supplies are `public`
///   (task ^3t0mbb1).
///
/// The import is plain, with no `@testable`, so the compiler is the first
/// assertion here: a member that loses `public`, or an error type that goes back
/// to `internal`, stops this file from compiling before a single test runs. The
/// bodies then drive that surface end to end over the scripted stub model, so
/// the suite measures behavior as well as reach.
@Suite("Router members over the public surface")
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

    /// Resolves a profile over `container`.
    ///
    /// The whole profile comes back, not the `.standard` handle alone: a handle
    /// holds its owning profile weakly, and a call on a handle whose profile was
    /// already released traps.
    ///
    /// - Parameter container: The resident model every slot of the profile
    ///   resolves to.
    /// - Returns: The resolved profile and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeProfile(
        container: any LoadedLLMContainer
    ) async throws -> (profile: LanguageModelProfile, directory: URL) {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(
                container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile, directory)
    }

    /// Resolves a profile over a scripted model answering with ``cannedObject``.
    ///
    /// The scripted backend runs the real (GPU-free) xgrammar-subset validation
    /// behind its guided entry point, so a rejected schema raises the same error
    /// a live model would.
    ///
    /// - Returns: The resolved profile and the temp directory the caller removes.
    /// - Throws: Whatever profile resolution throws.
    private static func makeGuidedProfile() async throws -> (profile: LanguageModelProfile, directory: URL) {
        try await makeProfile(container: ConfiguredLLMContainer(responseText: cannedObject))
    }

    // MARK: - respond(to:matching:)

    @Test("respond(to:matching:) answers a consumer outside the module with a JSONValue")
    @MainActor
    func respondMatchingReturnsAJSONValue() async throws {
        let (profile, directory) = try await Self.makeGuidedProfile()
        defer { try? FileManager.default.removeItem(at: directory) }

        let value = try await profile.standard.respond(to: Self.prompt, matching: Self.objectSchema)

        #expect(value == Self.parsedCannedObject)
    }

    // MARK: - GuidedRequestError

    @Test("a rejected schema throws a GuidedRequestError a consumer catches by type")
    @MainActor
    func respondMatchingThrowsANameableGuidedRequestError() async throws {
        let (profile, directory) = try await Self.makeGuidedProfile()
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

    // MARK: - Minimal conformance to LoadedLLMContainer and LanguageModelSessionBackend

    /// The chunks ``MinimalBackend`` streams for a turn, in order.
    ///
    /// More than one chunk, because the inherited
    /// `streamResponseFragments(to:maxTokens:)` must carry every chunk of a
    /// turn, in order. A single chunk would not show that.
    private static let minimalChunks = ["the defaults reach ", "an out-of-module conformer"]

    /// The whole reply a turn over ``MinimalBackend`` must produce.
    private static var minimalAnswer: String { minimalChunks.joined() }

    /// A session backend that writes only the members
    /// ``LanguageModelSessionBackend`` still requires of a conformer.
    ///
    /// It names no `streamResponseFragments(to:maxTokens:)`, no
    /// `makeFork(tools:)` and no `replacingTranscript(_:)`. Each of those three
    /// has a `public` default the protocol supplies, so this type inherits it.
    /// Were one of them to lose `public`, this file's plain import would stop
    /// seeing it and the compiler would reject the conformance.
    ///
    /// The suite's other stubs cannot stand in here. They reach the router
    /// through `@testable import`, which sees an `internal` default as well as
    /// a `public` one, so a conformance written against them measures nothing
    /// about the module boundary. Writing the omission out is the whole point
    /// of this type.
    private final class MinimalBackend: LanguageModelSessionBackend {
        /// The chunks this backend streams for a turn, in order.
        private let chunks: [String]

        /// Creates a backend.
        ///
        /// - Parameter chunks: The chunks to stream for each turn, in order.
        init(chunks: [String]) {
            self.chunks = chunks
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            chunks.joined()
        }

        /// Answers exactly as ``respond(to:maxTokens:)`` does, and ignores
        /// `grammar`. This backend holds a canned script, not a model, so
        /// nothing here can obey a grammar. The case below makes no guided call.
        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            chunks.joined()
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            let chunks = chunks
            return AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }

        func makeFork() -> any LanguageModelSessionBackend {
            MinimalBackend(chunks: chunks)
        }

        /// Reports an empty transcript. This backend accumulates no history,
        /// which is the least a conformer can report and still be honest.
        func transcriptEntries() -> [Transcript.Entry] {
            []
        }

        /// Reports no usage, which the protocol admits for a backend that
        /// cannot meter a turn.
        func usageTokenCounts() -> (input: Int, output: Int)? {
            nil
        }
    }

    /// A resident model that writes only the two factories
    /// ``LoadedLLMContainer`` still requires of a conformer.
    ///
    /// It names no `makeSession(instructions:tools:)`, no
    /// `makeSession(transcript:tools:)` and no `languageModel`, each of which
    /// has a `public` default the protocol supplies.
    private struct MinimalContainer: LoadedLLMContainer {
        /// The chunks every backend this container vends streams for a turn.
        let chunks: [String]

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            MinimalBackend(chunks: chunks)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            MinimalBackend(chunks: chunks)
        }
    }

    @Test("a container and a backend that write only their required members drive a whole turn")
    @MainActor
    func minimalConformersDriveATurn() async throws {
        let (profile, directory) = try await Self.makeProfile(
            container: MinimalContainer(chunks: Self.minimalChunks))
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = profile.standard.makeSession(instructions: nil)

        // A streaming turn reads the backend through
        // `streamResponseFragments(to:maxTokens:)`, which ``MinimalBackend``
        // does not write. The reply therefore measures the inherited default,
        // and it measures the whole of it: a default that dropped a chunk, or
        // that reported one as a restart, gives a shorter reply than this.
        let outcome = try await session.respond(to: Self.prompt, maxTokens: nil, observing: nil)

        #expect(outcome.reply == Self.minimalAnswer)
    }
}
