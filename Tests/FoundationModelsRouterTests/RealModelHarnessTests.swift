import Foundation
import FoundationModels
import FoundationModelsRouterRealModelSupport
import Testing

@testable import FoundationModelsRouter

// MARK: - Suite

/// Hermetic proof that ``RealModelHarness`` builds the profile the three
/// hand-written copies built before they moved onto it.
///
/// The move could not be proved by running its callers.
/// ``CompactionRoundTripIntegrationTests`` and
/// ``SessionTreeRestorationIntegrationTests`` are gated suites in the nested
/// `IntegrationTests/` package, which a plain `swift test` cannot see, and each
/// one loads a real model — which is why the card that added
/// ``RealModelHarness`` left all three copies in place rather than moving them
/// on a compile alone. Both stated a limit of 20 minutes against the 30B model
/// then. Task ^k0d30s4 moved both to a two-minute budget, and both have no
/// time limit now. The round
/// trip drives `mlx-community/Qwen2.5-3B-Instruct-4bit` (task ^k0d30s4); the
/// argument for this suite is unchanged, because a gated suite still cannot
/// run on a box with no model.
///
/// So the harness was split instead. Everything about the profile that does not
/// need a model — ``RealModelHarness/makeResolution(slot:model:context:)`` and
/// ``RealModelHarness/makeDurableRecording(recordingsDir:)``
/// — is a function of its own, and the container the rest needs is taken as
/// `any LoadedLLMContainer` so a stand-in satisfies it. The stand-in is this
/// target's own ``UndrivenLanguageModelContainer``: it holds no model at all,
/// which is the whole reason
/// ``RealModelHarness/make(model:context:container:samplingMode:cacheDir:recordingsDir:routerId:)``
/// takes the protocol rather than the concrete ``MLXFoundationModelsContainer``
/// — the concrete type wraps a real resident MLX model and cannot be
/// constructed without one. Every fact the two suites depend on is then
/// readable here in milliseconds.
///
/// ## What this suite does not reach
///
/// No assertion here concerns the real model's own behavior: a session
/// generating real text over a real container stays the gated suites' work.
@Suite("RealModelHarness profile shape (ungated)")
struct RealModelHarnessTests {
    /// The model every profile built here is stamped with. Never loaded — the
    /// harness records what a caller loaded rather than loading anything.
    private static let model: ModelRef = "mlx-community/probe-model"

    /// A working context that is NOT `ScriptedSessionContext.tokens`, the
    /// window most tests state, so a build that silently used that window is
    /// visible.
    ///
    /// The number ``CompactionRoundTripIntegrationTests`` resolves at, which is
    /// the smaller window that makes its scripted answers cross the trigger.
    private static let context = 2048

    /// Makes a fresh, empty pair of directories for one profile to cache and
    /// record under, and removes them when `body` returns.
    ///
    /// - Parameter body: What to run against the two directories.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` throws.
    private static func withTemporaryDirectories<T>(_ body: (URL, URL) throws -> T) rethrows -> T {
        let directories = TestDirectories(prefix: "RealModelHarnessTests")
        defer { directories.remove() }
        return try body(directories.cacheDir, directories.recordingsDir)
    }

    // MARK: - The resolution each hand-built copy produced

    /// Each slot resolves to the literal resolution the hand-built copies
    /// wrote.
    @Test("every slot resolves to exactly what the hand-built copies resolved to")
    func everySlotResolvesToWhatTheHandBuiltCopiesDid() {
        for slot in [ModelSlot.standard, .flash, .embedding] {
            let resolution = RealModelHarness.makeResolution(slot: slot, model: Self.model, context: Self.context)

            // Spelled out rather than compared field by field: this is the
            // literal `SlotResolution` both `CompactionRoundTripIntegrationTests`
            // and the continuity eval runner wrote by hand, and an added field
            // with a different default would fail this equality.
            #expect(
                resolution == SlotResolution(
                    slot: slot,
                    remainingBudgetBytes: 0,
                    chosen: Self.model,
                    considered: [],
                    contextTokens: Self.context
                ))
        }
    }

    // MARK: - The index.md a restore reads

    /// The instructions of the session the index test vends.
    private static let instructions = "You are a terse assistant."

    /// The durable recording of the harness records under the recordings
    /// folder it is given, at the full level, with no resolved profile.
    @Test("the durable recording records everything under the recordings folder, with no profile")
    func durableRecordingRecordsEverythingWithNoProfile() {
        Self.withTemporaryDirectories { _, recordingsDir in
            let recording = RealModelHarness.makeDurableRecording(recordingsDir: recordingsDir)

            #expect(recording.root == recordingsDir)
            #expect(recording.indexWriter.writes)
            #expect(recording.indexWriter.recordingLevel == .full)
            #expect(recording.indexWriter.profile == nil)
        }
    }

    /// A session vended from a harness profile writes the `index.md` that a
    /// restore reads its facts from, stamped with the model, the context and
    /// the router id of the harness.
    @Test("a harness session writes the index.md a restore reads its facts from")
    func harnessSessionWritesTheIndexARestoreReads() async throws {
        let directories = TestDirectories(prefix: "RealModelHarnessTests")
        defer { directories.remove() }
        let profile = RealModelHarness.make(
            model: Self.model,
            context: Self.context,
            container: UndrivenLanguageModelContainer(),
            cacheDir: directories.cacheDir,
            recordingsDir: directories.recordingsDir
        )
        let session = profile.standard.makeSession(configuration: SessionConfiguration(instructions: Self.instructions))
        await session.close()

        // Driven for real against a directory, rather than compared field by
        // field: the `index.md` is the whole of what
        // `TranscriptTree.load(under:)` reads a restored session's facts
        // from, so the file on disk is the contract.
        let record = try #require(try SessionIndexFile.read(in: session.recordingDirectory))
        #expect(record.sessionId == session.id)
        #expect(record.slot == .standard)
        #expect(record.model == Self.model)
        #expect(record.context == Self.context)
        #expect(record.routerId == profile.standard.routerId)
        #expect(record.instructions == Self.instructions)
        #expect(record.recordingLevel == .full)
    }

    // MARK: - The whole profile

    /// Every handle of a built profile carries the model, the context and
    /// the one router id of the harness.
    @Test("the built profile stamps every slot with the model, the context and the router's id")
    func builtProfileStampsEverySlot() {
        Self.withTemporaryDirectories { cacheDir, recordingsDir in
            let profile = RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                cacheDir: cacheDir,
                recordingsDir: recordingsDir
            )

            // The literal, not `RealModelHarness.definitionName` — comparing a
            // build against the constant it was built from asserts nothing, and
            // a silent rename of the constant would keep such a check green.
            #expect(profile.definitionName == "real-model-harness")
            #expect(profile.standard.slot == .standard)
            #expect(profile.flash.slot == .flash)
            #expect(profile.embedding.slot == .embedding)

            for chosen in [profile.standard.chosen, profile.flash.chosen, profile.embedding.chosen] {
                #expect(chosen == Self.model)
            }
            for resolution in [profile.standard.resolution, profile.flash.resolution, profile.embedding.resolution] {
                #expect(resolution.contextTokens == Self.context)
                #expect(resolution.chosen == Self.model)
            }
            // Every handle reports the ONE router that owns the recording root,
            // which is what makes `profile.standard.routerId` the id its callers
            // read back in place of a returned `Router`.
            let routerId = profile.standard.routerId
            #expect(profile.flash.routerId == routerId)
            #expect(profile.embedding.routerId == routerId)
        }
    }

    /// The sampling mode the harness gets reaches both generation handles.
    @Test("the built profile gives the sampling mode it was given to both generation handles")
    func builtProfileGivesTheSamplingModeToBothGenerationHandles() {
        Self.withTemporaryDirectories { cacheDir, recordingsDir in
            let profile = RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                samplingMode: .greedy,
                cacheDir: cacheDir,
                recordingsDir: recordingsDir
            )

            // The mode belongs to the router, not to the container
            // (`model-pool.md` §2.5). A gated suite states its pin here one
            // time, and each session the profile vends gives that pin to
            // `makeSession`. A container that stored the mode is gone, so a
            // handle that did not carry it would decode with the provider
            // default and the suite would lose its pin.
            #expect(profile.standard.samplingMode == .greedy)
            #expect(profile.flash.samplingMode == .greedy)
        }
    }

    /// A profile built with the router id of another continues its recording
    /// root; a profile built with no id gets a new one.
    @Test("a profile stamped with an existing router id continues that router's recording root")
    func profileStampedWithAnExistingRouterIdContinuesThatRoot() {
        // The whole reason `make` needs a `routerId` at all: both gated suites
        // record a tree under one router, discard everything, then build a
        // SECOND profile that has to read the same root back.
        Self.withTemporaryDirectories { cacheDir, recordingsDir in
            let first = RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                cacheDir: cacheDir,
                recordingsDir: recordingsDir
            )
            let second = RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                cacheDir: cacheDir,
                recordingsDir: recordingsDir,
                routerId: first.standard.routerId
            )
            let unstamped = RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                cacheDir: cacheDir,
                recordingsDir: recordingsDir
            )

            #expect(second.standard.routerId == first.standard.routerId)
            #expect(unstamped.standard.routerId != first.standard.routerId)
        }
    }

    // MARK: - The embedding slot no caller drives

    /// An embed through the embedding slot of a harness profile records an
    /// issue.
    @Test("the embedding slot every harness profile carries records an issue when anything embeds through it")
    func embeddingSlotRecordsAnIssueWhenDriven() async {
        let embedder = Self.withTemporaryDirectories { cacheDir, recordingsDir in
            RealModelHarness.make(
                model: Self.model,
                context: Self.context,
                container: UndrivenLanguageModelContainer(),
                cacheDir: cacheDir,
                recordingsDir: recordingsDir
            ).embedding.container
        }

        // The harness loads one generation model and stamps it into all three
        // slots, so the `.embedding` handle stands over a stub that holds no
        // embedding model at all. A call that reaches it is a suite driving a
        // slot the harness never loaded for, and the empty answer alone would
        // read as a result rather than as a mistake. This is the tripwire
        // `RealToolAnswerComparisonTests` carried on its own copy of the stub
        // before that suite moved onto the harness (task ^zz6kam0); it is here
        // now, so every harness caller has it.
        await withKnownIssue("the harness embedding stub records an issue when it is driven") {
            let vectors = try await embedder.embed(texts: ["anything"])
            #expect(vectors.isEmpty)
        }
    }
}
