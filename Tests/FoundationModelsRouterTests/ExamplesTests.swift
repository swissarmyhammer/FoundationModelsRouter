import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

#if canImport(FoundationModels)
    import FoundationModels
#endif

/// # Canonical usage reference for FoundationModelsRouter.
///
/// This suite is the **living documentation** for the router's public API: each
/// `@Test` is a self-contained, copy-pasteable "how do I…" example whose body
/// reads exactly like the code a real consumer writes — author a
/// ``ProfileDefinition``, resolve it on a ``Router``, then drive the resolved
/// ``LanguageModelProfile``. Read these first to learn the call patterns.
///
/// Unlike the gated milestone-7 integration suite (which drives real MLX over
/// the network/GPU), everything here runs **offline in the normal unit-test
/// target** — no download, no network, no GPU — so it stays green in CI. The
/// only non-production code is the ``ExampleHarness`` setup helper below, which
/// injects offline stubs for the router's three seams (``MachineProbe``,
/// ``MetadataSource``, ``ModelLoader``) and an ``InMemoryRecorder``. In
/// production you construct `Router(recordingsDir:)` with a configured
/// `LiveModelLoader` instead; every line *after* the `ExampleHarness.makeRouter`
/// call is real usage.
@Suite("Examples: canonical usage of the public API")
struct ExamplesTests {
    // MARK: - Unit-test seam (the ONLY non-production code in this file)

    /// Offline stubs and a factory that stand in for the router's live seams so
    /// every example runs with no network, GPU, or download.
    ///
    /// In production, `Router` is built with a configured `LiveModelLoader` and a
    /// durable `recordingsDir`; here the harness injects fixed-budget /
    /// canned-output stubs and an in-memory recorder. This is the single place
    /// the examples depart from production code — everything the example bodies
    /// do with the returned `Router` is the real public API.
    private enum ExampleHarness {
        /// A machine probe reporting a fixed, generous budget so every authored
        /// candidate fits and the biggest-preference model wins each slot.
        private struct StubProbe: MachineProbe {
            let chip: String
            let totalRAM: Int64
            let recommendedMaxWorkingSetSize: Int64
        }

        /// A metadata source returning the same tiny canned repo metadata for
        /// every candidate, so sizing is deterministic and offline.
        private struct StubMetadataSource: MetadataSource {
            let raw: RawRepoMetadata
            func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
                raw
            }
        }

        /// A loaded generation container that returns a canned response through
        /// every entry point — plain, streamed, and grammar-guided (after running
        /// the real, GPU-free grammar validation) — the stand-in for the MLX +
        /// xgrammar engine.
        private struct StubLLMContainer: LoadedLLMContainer {
            let canned: String

            func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
                StubSessionBackend(responseText: canned)
            }

            func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
                StubSessionBackend(entries: Array(transcript))
            }
        }

        /// A loaded embedding container that returns fixed-length vectors.
        private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
            let dimension: Int
            func embed(texts: [String]) async throws -> [[Float]] {
                texts.map { _ in [Float](repeating: 0, count: dimension) }
            }
        }

        /// A model loader that vends the stub containers with no download or GPU
        /// work, reporting a single fake byte total so progress advances.
        private struct StubModelLoader: ModelLoader {
            let canned: String
            let perSlotCanned: [ModelSlot: String]
            let dimension: Int

            func loadLLM(
                ref: ModelRef,
                slot: ModelSlot,
                context: Int,
                reporting: @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> any LoadedLLMContainer {
                reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
                return StubLLMContainer(canned: perSlotCanned[slot] ?? canned)
            }

            func loadEmbedder(
                ref: ModelRef,
                slot: ModelSlot,
                reporting: @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> any LoadedEmbeddingContainer {
                reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
                return StubEmbeddingContainer(dimension: dimension)
            }

            func preload(container: any LoadedModelContainer) async throws {}
        }

        /// Tiny canned repo metadata: a 2-layer attention shape and a single
        /// 10 MB weight shard, so every candidate's footprint is negligible.
        private static var rawMetadata: RawRepoMetadata {
            let configJSON = Data(
                """
                {
                    "num_hidden_layers": 2,
                    "num_attention_heads": 8,
                    "num_key_value_heads": 2,
                    "head_dim": 16,
                    "hidden_size": 128
                }
                """.utf8
            )
            let treeJSON = Data(
                """
                [
                    {"type": "file", "path": "model.safetensors", "size": 10000000}
                ]
                """.utf8
            )
            return RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
        }

        /// Builds an offline `Router` for an example.
        ///
        /// - Parameters:
        ///   - cannedResponse: The text every generation entry point returns for
        ///     any slot not overridden by `cannedResponses`.
        ///   - cannedResponses: Per-slot overrides of `cannedResponse`, so an
        ///     example can prove two calls really hit two different resident
        ///     models by asserting on their distinct outputs.
        ///   - embeddingDimension: The length of every embedding vector.
        /// - Returns: A `Router` whose seams are offline stubs, recording to
        ///   memory under a throwaway temporary cache directory.
        static func makeRouter(
            cannedResponse: String = "OK",
            cannedResponses: [ModelSlot: String] = [:],
            embeddingDimension: Int = 768
        ) -> Router {
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ExamplesTests-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            return Router(
                cacheDir: cacheDir,
                recorder: InMemoryRecorder(),
                probe: StubProbe(
                    chip: "Apple Example",
                    totalRAM: 64 << 30,
                    recommendedMaxWorkingSetSize: 48 << 30
                ),
                metadataSource: StubMetadataSource(raw: rawMetadata),
                loader: StubModelLoader(
                    canned: cannedResponse,
                    perSlotCanned: cannedResponses,
                    dimension: embeddingDimension
                )
            )
        }
    }

    // MARK: - Resolve + progress

    @Test("Author a ProfileDefinition and resolve it, watching progress reach .ready")
    @MainActor
    func resolveProfileObservingProgress() async throws {
        let router = ExampleHarness.makeRouter()

        // Author a profile: list candidate models per slot, biggest/best first.
        // Resolution picks the highest-preference candidate that fits this machine.
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: [
                "mlx-community/Qwen2.5-14B-Instruct-4bit",
                "mlx-community/Qwen2.5-7B-Instruct-4bit",
            ],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )

        // `ResolutionProgress` is `@Observable`, so a SwiftUI view can bind to it
        // and drive a `ProgressView` as resolution advances.
        let progress = ResolutionProgress()
        let profile = try await router.resolve(profile: coding, reporting: progress)

        // Resolution succeeded: every slot is resident and the bar is full.
        #expect(progress.phase == .ready)
        #expect(progress.fraction == 1.0)

        // The biggest-preference candidate won each generation slot.
        #expect(profile.definitionName == "coding")
        #expect(profile.standard.chosen == "mlx-community/Qwen2.5-14B-Instruct-4bit")
        #expect(profile.flash.chosen == "mlx-community/Qwen2.5-3B-Instruct-4bit")
    }

    // MARK: - Generation

    @Test("Open a session and respond to a prompt")
    @MainActor
    func generateWithASession() async throws {
        let router = ExampleHarness.makeRouter(cannedResponse: "The keyword is `final`.")
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        // A session carries system instructions and its own conversation cache.
        let session = profile.standard.makeSession(
            instructions: "You are a terse Swift expert."
        )
        let answer = try await session.respond(
            to: "Which Swift keyword marks a class that cannot be subclassed?"
        )
        #expect(answer == "The keyword is `final`.")
    }

    @Test("Stream a response fragment by fragment")
    @MainActor
    func streamAResponse() async throws {
        let router = ExampleHarness.makeRouter(cannedResponse: "Hello, world!")
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        let session = profile.standard.makeSession()

        // Consume the stream as fragments arrive, e.g. to render tokens live.
        var streamed = ""
        for try await fragment in await session.streamResponse(to: "Say hello.") {
            streamed += fragment
        }
        #expect(streamed == "Hello, world!")
    }

    // MARK: - Multi-model direct generation

    @Test("Route work across two resident models: flash triages, standard answers")
    @MainActor
    func multiModelDirectGeneration() async throws {
        let router = ExampleHarness.makeRouter(cannedResponses: [
            .flash: "billing",
            .standard: "Refunds for Q3 invoices post within 5–7 business days.",
        ])
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )

        // One resolve makes both generation models resident together — no
        // reload between the two calls below.
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())
        #expect(profile.standard.chosen != profile.flash.chosen)

        // Cheap triage: route the light classification work to `flash`.
        let triage = profile.flash.makeSession(
            instructions: "Classify the support ticket into one category word."
        )
        let category = try await triage.respond(
            to: "My Q3 invoice has a discrepancy in the refund total."
        )
        #expect(category == "billing")

        // Heavyweight answer: route the full response to `standard`.
        let answer = profile.standard.makeSession(
            instructions: "You are a support agent. Write a helpful, precise reply."
        )
        let reply = try await answer.respond(
            to: "Explain our \(category) policy for the customer's Q3 invoice."
        )
        #expect(reply == "Refunds for Q3 invoices post within 5–7 business days.")

        // The two calls really hit two different resident models.
        #expect(category != reply)
    }

    // MARK: - Embedding

    @Test("Embed strings and read the vector dimension")
    @MainActor
    func embedStrings() async throws {
        let router = ExampleHarness.makeRouter(embeddingDimension: 384)
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        let embedder = profile.embedding
        #expect(embedder.dimension == 384)

        let vectors = try await embedder.embed(texts: [
            "func add(_ a: Int, _ b: Int) -> Int { a + b }",
            "let total = a + b",
        ])
        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { $0.count == embedder.dimension })
    }

    // MARK: - Guided generation: raw

    @Test("Guided (raw): constrain output to a grammar via respond(to:following:) and makeGuidedSession")
    @MainActor
    func guidedRawConstrainedText() async throws {
        let router = ExampleHarness.makeRouter(cannedResponse: #"{"intent":"bugfix"}"#)
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        // A grammar guarantees the raw output is syntactically valid.
        let grammar = Grammar.jsonSchema(
            #"{"type":"object","properties":{"intent":{"type":"string"}}}"#
        )

        // One-shot: `respond(to:following:)` returns the raw constrained text.
        let raw = try await profile.standard.respond(
            to: "Classify this change: 'fix the null crash'.",
            following: grammar
        )
        #expect(raw == #"{"intent":"bugfix"}"#)

        // Reusable: `makeGuidedSession` applies the grammar to every turn, and the
        // grammar travels with the session (so a fork inherits it).
        let session = profile.standard.makeGuidedSession(grammar: grammar)
        #expect(session.grammar == grammar)
        let next = try await session.respond(to: "Classify: 'add dark mode'.")
        #expect(next == #"{"intent":"bugfix"}"#)
    }

    // MARK: - Guided generation: dynamic JSON

    @Test("Guided (dynamic): constrain to a runtime schema via respond(to:matching:) into a JSONValue")
    @MainActor
    func guidedDynamicJSONValue() async throws {
        let router = ExampleHarness.makeRouter(
            cannedResponse: #"{"language":"python","confident":true}"#
        )
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        // The schema is known only at runtime (no Swift type), so the output comes
        // back as a dynamically-typed `JSONValue`.
        let schema = """
            {"type":"object","properties":{"language":{"type":"string"},"confident":{"type":"boolean"}},"required":["language"]}
            """
        let value = try await profile.standard.respond(
            to: "Detect the language of: print('hi')",
            matching: schema
        )
        #expect(
            value == .object([
                "language": .string("python"),
                "confident": .bool(true),
            ])
        )
    }

    // MARK: - Subagent fan-out

    @Test("Fan out N short-lived subagents by forking one session")
    @MainActor
    func subagentFanOutByForking() async throws {
        let router = ExampleHarness.makeRouter(cannedResponse: "done")
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )
        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        // A planner session establishes shared context once; each subagent is a
        // fork that inherits its cached prefix and then diverges independently.
        let planner = profile.standard.makeSession(instructions: "You are the planner.")

        let subagentCount = 4
        var subagents: [RoutedSession] = []
        for _ in 0..<subagentCount {
            subagents.append(try await planner.fork(workingDirectory: nil))
        }

        // Each fork is a distinct child nested under the planner.
        #expect(subagents.count == subagentCount)
        #expect(subagents.allSatisfy { $0.parentId == planner.id })
        #expect(Set(subagents.map(\.id)).count == subagentCount)

        // Every subagent responds on its own.
        for subagent in subagents {
            let reply = try await subagent.respond(to: "Do your part.")
            #expect(reply == "done")
        }
    }

    // MARK: - Residency lifecycle

    @Test("Residency: one active profile at a time; release() frees the slot")
    @MainActor
    func residencyOneActiveProfileAndRelease() async throws {
        let router = ExampleHarness.makeRouter()
        let coding = ProfileDefinition(
            name: "coding",
            description: "Local coding assistant.",
            standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
            flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
            embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
        )

        let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

        // The router holds one active profile at a time so it never over-commits
        // RAM: a second resolve is rejected while the first is resident.
        await #expect(throws: RouterError.self) {
            _ = try await router.resolve(profile: coding, reporting: ResolutionProgress())
        }

        // Releasing evicts the resident models and frees the residency slot.
        await profile.release()

        // Now another profile can be resolved on the same router.
        _ = try await router.resolve(profile: coding, reporting: ResolutionProgress())
    }

    // MARK: - Guided generation: typed

    #if canImport(FoundationModels)
        /// A `@Generable` type whose schema is derived automatically and whose
        /// fields the guided response is decoded back into.
        @Generable
        struct CodeReview: Equatable {
            @Guide(description: "A one-line summary of the review.")
            var summary: String

            @Guide(description: "The number of lines reviewed.")
            var lineCount: Int
        }

        @Test("Guided (typed): constrain to a @Generable type via respond(to:generating:)")
        @MainActor
        func guidedTypedGenerable() async throws {
            let router = ExampleHarness.makeRouter(
                cannedResponse: #"{"summary":"Looks good.","lineCount":42}"#
            )
            let coding = ProfileDefinition(
                name: "coding",
                description: "Local coding assistant.",
                standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
                flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
                embedding: ["mlx-community/bge-small-en-v1.5-4bit"]
            )
            let profile = try await router.resolve(profile: coding, reporting: ResolutionProgress())

            // The schema is derived from the type, and the constrained output is
            // decoded straight back into it — one source of truth for the shape.
            let review = try await profile.standard.respond(
                to: "Review this diff.",
                generating: CodeReview.self
            )
            #expect(review == CodeReview(summary: "Looks good.", lineCount: 42))
        }
    #endif  // canImport(FoundationModels)
}
