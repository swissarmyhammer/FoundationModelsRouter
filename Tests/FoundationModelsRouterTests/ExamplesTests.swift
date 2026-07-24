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
        private struct StubLLMContainer: PlainTranscriptStubContainer {
            let canned: String

            func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
                StubSessionBackend(responseText: canned)
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

    // MARK: - Compaction

    /// Minimal router-building support for the two compaction examples below,
    /// kept separate from ``ExampleHarness``: both examples need a single,
    /// test-retained backend a test can drive/mutate directly (climbing
    /// simulated usage, or a one-time context-overflow failure) rather than
    /// ``ExampleHarness``'s fixed-budget resolution machinery, which builds a
    /// fresh canned backend per slot with no seam for a test to hold onto.
    private enum CompactionExampleHarness {
        private struct StubProbe: MachineProbe {
            let chip: String
            let totalRAM: Int64
            let recommendedMaxWorkingSetSize: Int64
        }

        private struct StubMetadataSource: MetadataSource {
            let raw: RawRepoMetadata
            func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata { raw }
        }

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
                """.utf8)
            let treeJSON = Data(
                """
                [
                    {"type": "file", "path": "model.safetensors", "size": 10000000}
                ]
                """.utf8)
            return RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
        }

        private struct StubEmbeddingContainer: LoadedEmbeddingContainer {
            let dimension: Int = 8
            func embed(texts: [String]) async throws -> [[Float]] {
                texts.map { _ in [Float](repeating: 0, count: dimension) }
            }
        }

        /// Vends the same `backend` instance for every slot — both examples
        /// below only ever open one session over `profile.standard`, and
        /// mutate `backend` directly between turns rather than
        /// reconfiguring the container.
        private struct FixedBackendContainer: LoadedLLMContainer {
            let backend: any LanguageModelSessionBackend
            func makeSession(instructions: String?) -> any LanguageModelSessionBackend { backend }
            func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend { backend }
        }

        private struct StubModelLoader: ModelLoader {
            let backend: any LanguageModelSessionBackend

            func loadLLM(
                ref: ModelRef,
                slot: ModelSlot,
                context: Int,
                reporting: @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> any LoadedLLMContainer {
                reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
                return FixedBackendContainer(backend: backend)
            }

            func loadEmbedder(
                ref: ModelRef,
                slot: ModelSlot,
                reporting: @escaping @Sendable (DownloadProgress) -> Void
            ) async throws -> any LoadedEmbeddingContainer {
                reporting(DownloadProgress(bytesDownloaded: 1, bytesTotal: 1))
                return StubEmbeddingContainer()
            }

            func preload(container: any LoadedModelContainer) async throws {}
        }

        /// Resolves a one-model profile whose working context is `context`
        /// and opens a `standard`-slot session driven entirely by `backend`.
        static func makeSession(
            over backend: any LanguageModelSessionBackend, context: Int
        ) async throws -> RoutedSession {
            let cacheDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("CompactionExample-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            let router = Router(
                cacheDir: cacheDir,
                recorder: InMemoryRecorder(),
                probe: StubProbe(chip: "Apple Example", totalRAM: 64 << 30, recommendedMaxWorkingSetSize: 48 << 30),
                metadataSource: StubMetadataSource(raw: rawMetadata),
                loader: StubModelLoader(backend: backend)
            )
            let profile = try await router.resolve(
                profile: ProfileDefinition(
                    name: "compaction-example",
                    description: "Compaction example profile.",
                    standard: ["mlx-community/Qwen2.5-14B-Instruct-4bit"],
                    flash: ["mlx-community/Qwen2.5-3B-Instruct-4bit"],
                    embedding: ["mlx-community/bge-small-en-v1.5-4bit"],
                    context: context
                ),
                reporting: ResolutionProgress()
            )
            return profile.standard.makeSession()
        }
    }

    @Test(
        "Proactive: check contextFill against a TokenBudget's trigger between turns and fold before it gets too high — exercises the shape of RoutedSession.compact(prompt:budget:)'s own doc example"
    )
    @MainActor
    func proactiveCompactionBetweenTurns() async throws {
        let backend = StubSessionBackend(responseText: "ok")
        let session = try await CompactionExampleHarness.makeSession(over: backend, context: 100_000)

        let budget = TokenBudget(limit: 100_000)
        var compactedAtTurn: Int?

        for turn in 0..<3 {
            // Simulated usage climbing turn over turn — 0.3, 0.6, 0.9 of the
            // 100,000-token context, folded into a genuine measured
            // before/after contextFill delta by the actor's own chokepoint
            // (StubSessionBackend.usageIncrement), the way a real model's
            // own usage grows as a conversation lengthens.
            backend.usageIncrement = (input: (turn + 1) * 30_000, output: 0)
            _ = try await session.respond(to: "turn \(turn)")

            // The proactive pattern (RoutedSession.compact(prompt:budget:)'s
            // own doc comment): check fill between turns, fold before it
            // gets too high — turns never die.
            if await session.contextFill >= budget.trigger {
                try await session.compact(budget: budget)
                compactedAtTurn = turn
            }
        }

        // The trigger fired exactly when the simulated usage crossed it —
        // this assertion is real evidence the pattern's fill-vs-trigger
        // comparison works against genuine measured contextFill, not a
        // tautology: a bug that stopped contextFill from climbing (or that
        // broke the `>=` comparison) would shift or drop this turn index.
        #expect(compactedAtTurn == 2)

        // Whether or not this toy transcript had anything left to actually
        // fold (that mechanics, and a real non-empty-stagesApplied fold, is
        // exhaustively covered by RoutedSessionCompactTests), compact()
        // never breaks the session: it keeps responding normally right
        // afterward.
        let response = try await session.respond(to: "still working")
        #expect(response == "ok")
    }

    /// Counts how many times an ``OverflowOnceBackend``'s
    /// ``OverflowOnceBackend/replacingTranscript(_:)`` was called — the only
    /// way to observe, from outside the session, that a `compact()` call
    /// actually performed a genuine fold. `RoutedSessionActor.compact(prompt:budget:)`
    /// only swaps its backend (calling `replacingTranscript(_:)`) when
    /// folding changed something; a no-op fold (already under target) never
    /// does. Shared across every backend a fold produces, since
    /// `replacingTranscript(_:)` returns a fresh instance each time.
    private final class ReplaceSpy: @unchecked Sendable {
        private(set) var replaceCount = 0
        func recordReplace() { replaceCount += 1 }
    }

    /// A backend that throws `LanguageModelError.contextSizeExceeded` on its
    /// very first call — simulating a turn that overflows the context — and
    /// responds normally on every call after, so a test can drive the
    /// reactive recovery pattern documented on
    /// ``RoutedSession/compact(prompt:budget:)``.
    ///
    /// Can be seeded with prior transcript content at construction, so the
    /// `compact()` call the reactive pattern drives has real content to fold
    /// (rather than a no-op on an empty transcript) — see
    /// ``seedEntries(turnCount:responseText:)``.
    private final class OverflowOnceBackend: LanguageModelSessionBackend, @unchecked Sendable {
        let responseText: String
        let replaceSpy: ReplaceSpy
        private(set) var entries: [Transcript.Entry]
        private var hasOverflowed: Bool

        init(
            responseText: String,
            entries: [Transcript.Entry] = [],
            hasOverflowed: Bool = false,
            replaceSpy: ReplaceSpy = ReplaceSpy()
        ) {
            self.responseText = responseText
            self.entries = entries
            self.hasOverflowed = hasOverflowed
            self.replaceSpy = replaceSpy
        }

        /// Synthetic prompt/response turns — long enough in aggregate,
        /// `turnCount` past `TurnTruncation`'s default 4-turn recency
        /// window, that a tight-enough `TokenBudget` forces a real fold
        /// (`TurnTruncation` actually dropping the oldest turns) rather than
        /// a no-op.
        static func seedEntries(turnCount: Int, responseText: String) -> [Transcript.Entry] {
            (0..<turnCount).flatMap { index -> [Transcript.Entry] in
                [
                    .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: "seed turn \(index)"))])),
                    .response(
                        Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))])
                    ),
                ]
            }
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            guard hasOverflowed else {
                hasOverflowed = true
                throw LanguageModelError.contextSizeExceeded(
                    .init(contextSize: 100, tokenCount: 150, debugDescription: "stub context overflow")
                )
            }
            entries.append(.prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])))
            entries.append(
                .response(Transcript.Response(assetIDs: [], segments: [.text(Transcript.TextSegment(content: responseText))])))
            return responseText
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(responseText)
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            responseText
        }

        func makeFork() -> any LanguageModelSessionBackend {
            OverflowOnceBackend(
                responseText: responseText, entries: entries, hasOverflowed: hasOverflowed, replaceSpy: replaceSpy)
        }

        func transcriptEntries() -> [Transcript.Entry] { entries }

        func usageTokenCounts() -> (input: Int, output: Int)? { nil }

        func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
            // Only reached when compact() actually folded something — a
            // no-op fold (already under target) never swaps the backend
            // (see RoutedSessionActor.compact(prompt:budget:)'s own doc
            // comment). The fresh backend is already past its one-time
            // overflow, seeded from the folded transcript.
            replaceSpy.recordReplace()
            return OverflowOnceBackend(
                responseText: responseText, entries: Array(transcript), hasOverflowed: true, replaceSpy: replaceSpy)
        }
    }

    /// The reactive recovery pattern documented on
    /// ``RoutedSession/compact(prompt:budget:)``: try the turn; if the
    /// backend's context overflowed, fold harder than the default 50% target
    /// and retry exactly once. Copied verbatim from that doc comment's own
    /// code sample so the two cannot silently drift apart.
    private func respondWithReactiveCompaction(
        session: RoutedSession, prompt: String, contextTokens: Int
    ) async throws -> String {
        do {
            return try await session.respond(to: prompt)
        } catch LanguageModelError.contextSizeExceeded {
            try await session.compact(budget: TokenBudget(limit: contextTokens, target: 0.35))
            return try await session.respond(to: prompt)
        }
    }

    @Test(
        "Reactive: catch LanguageModelError.contextSizeExceeded, compact with a lowered target, and retry once — exercises the shape of RoutedSession.compact(prompt:budget:)'s own doc example"
    )
    @MainActor
    func reactiveCompactionRecoversFromContextOverflow() async throws {
        // Seed enough real transcript content (more than TurnTruncation's
        // 4-turn recency window) that the lowered-target compact() this
        // test drives actually folds something real, not a no-op — so this
        // test would fail if a future change dropped the compact() call
        // from the reactive pattern, or broke it, rather than passing
        // vacuously on the retry alone (which only depends on the stub's
        // one-time-overflow behavior).
        let seedText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 12)
        let seedEntries = OverflowOnceBackend.seedEntries(turnCount: 6, responseText: seedText)
        let replaceSpy = ReplaceSpy()
        let backend = OverflowOnceBackend(responseText: "recovered", entries: seedEntries, replaceSpy: replaceSpy)

        // Derive a context tight enough that the reactive pattern's own
        // hardcoded 0.35 target sits strictly between the seeded
        // transcript's real recency-window-only estimate and its full
        // pre-fold estimate — guaranteeing TurnTruncation alone lands under
        // target (no need for the model-assisted Summarization stage, which
        // this stub cannot service).
        let (header, turns) = TranscriptTurns.split(seedEntries)
        let (_, recent) = TranscriptTurns.partition(turns, keepRecentTurns: 4)
        let recencyOnlyEstimate = Compactor.estimatedTokenCount(of: Transcript(entries: header + recent.flatMap(\.entries)))
        let preFoldEstimate = Compactor.estimatedTokenCount(of: Transcript(entries: seedEntries))
        let midTarget = (recencyOnlyEstimate + preFoldEstimate) / 2
        let contextTokens = Int(Double(midTarget) / 0.35)

        let session = try await CompactionExampleHarness.makeSession(over: backend, context: contextTokens)

        let reply = try await respondWithReactiveCompaction(
            session: session, prompt: "keep going", contextTokens: contextTokens)

        #expect(reply == "recovered")
        // The compact() call inside the reactive helper genuinely folded
        // the seeded transcript (swapped the backend) rather than no-op'ing
        // — real evidence the reactive pattern recovers by shrinking the
        // transcript, not just by luck of a one-time stub failure.
        #expect(replaceSpy.replaceCount == 1)
    }
}
