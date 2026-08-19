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
/// ``SessionTreeRestorationIntegrationTests`` are gated suites with a 20-minute
/// limit against a 30B model, which is why the card that added
/// ``RealModelHarness`` left all three copies in place rather than moving them
/// on a compile alone.
///
/// So the harness was split instead. Everything about the profile that does not
/// need a model — ``RealModelHarness/makeResolution(slot:model:context:)`` and
/// ``RealModelHarness/makeDurableRecording(slot:model:context:recordingsDir:routerId:)``
/// — is a function of its own, and the container the rest needs is taken as
/// `any LoadedLLMContainer` so a stand-in satisfies it. The stand-in is this
/// target's own ``UndrivenLanguageModelContainer``: it holds no model at all,
/// which is the whole reason
/// ``RealModelHarness/make(model:context:container:cacheDir:recordingsDir:routerId:)``
/// takes the protocol rather than the concrete ``MLXFoundationModelsContainer``
/// — the concrete type wraps a real resident MLX model and cannot be
/// constructed without one. Every fact the two suites depend on is then
/// readable here in milliseconds.
///
/// ## What this suite does not reach
///
/// Two things. ``ResidentModelGates`` is a `struct`, so the fact that
/// `.standard` and `.flash` share ONE set is not observable from outside the
/// build — it is held by the one `let` inside the harness and by that comment
/// alone. And no assertion here concerns the real model's own behavior: a
/// session generating real text over a real container stays the gated suites'
/// work.
@Suite("RealModelHarness profile shape (ungated)")
struct RealModelHarnessTests {
    /// The model every profile built here is stamped with. Never loaded — the
    /// harness records what a caller loaded rather than loading anything.
    private static let model: ModelRef = "mlx-community/probe-model"

    /// A working context that is NOT ``ProfileDefinition/defaultContext``, so a
    /// build that silently fell back to the default is visible.
    ///
    /// The number ``CompactionRoundTripIntegrationTests`` resolves at, which is
    /// the smaller window that makes its scripted turns cross the trigger.
    private static let context = 2048

    /// Makes a fresh, empty pair of directories for one profile to cache and
    /// record under, and removes them when `body` returns.
    ///
    /// - Parameter body: What to run against the two directories.
    /// - Returns: Whatever `body` returned.
    /// - Throws: Whatever `body` throws.
    private static func withTemporaryDirectories<T>(_ body: (URL, URL) throws -> T) rethrows -> T {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealModelHarnessTests-cache-\(UUID().uuidString)", isDirectory: true)
        let recordingsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealModelHarnessTests-recordings-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        return try body(cacheDir, recordingsDir)
    }

    // MARK: - The resolution each hand-built copy produced

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

    @Test("stating the profile default explicitly resolves to what the omitted default resolved to")
    func statingTheProfileDefaultMatchesOmittingIt() {
        // `SessionTreeRestorationIntegrationTests` built its own resolutions
        // with no `contextTokens:` argument at all, so every slot took
        // `SlotResolution`'s own default. The harness has no default to inherit,
        // so that suite now states `ProfileDefinition.defaultContext`. This is
        // the equality that makes those two spellings the same profile.
        let stated = RealModelHarness.makeResolution(
            slot: .standard, model: Self.model, context: ProfileDefinition.defaultContext)
        let omitted = SlotResolution(
            slot: .standard, remainingBudgetBytes: 0, chosen: Self.model, considered: [])

        #expect(stated == omitted)
    }

    // MARK: - The sidecar a restore reads

    @Test("the durable recording writes the session.json a restore reads its facts from")
    func durableRecordingWritesTheSidecarARestoreReads() throws {
        try Self.withTemporaryDirectories { _, recordingsDir in
            let routerId = ULID.generate()
            let recording = RealModelHarness.makeDurableRecording(
                slot: .standard,
                model: Self.model,
                context: Self.context,
                recordingsDir: recordingsDir,
                routerId: routerId
            )
            #expect(recording.root == recordingsDir)

            // Driven for real against a directory, rather than compared field by
            // field: `session.json` is the whole of what
            // `TranscriptTree.load(under:)` reads a restored session's facts
            // from, so the file on disk is the contract, not the writer's own
            // stored properties.
            let sessionDirectory = recordingsDir.appendingPathComponent(
                ULID.generate().description, isDirectory: true)
            recording.sidecarWriter.write(
                instructions: "You are a terse assistant.",
                grammar: nil,
                forkedAtEntryCount: nil,
                forkedAtHistoryOrdinal: nil,
                workingDirectory: sessionDirectory,
                to: sessionDirectory
            )

            let sidecarURL = sessionDirectory.appendingPathComponent("session.json", isDirectory: false)
            let sidecar = try JSONDecoder().decode(SessionSidecar.self, from: Data(contentsOf: sidecarURL))
            #expect(sidecar.slot == .standard)
            #expect(sidecar.model == Self.model)
            #expect(sidecar.context == Self.context)
            #expect(sidecar.routerId == routerId)
            #expect(sidecar.instructions == "You are a terse assistant.")
        }
    }

    // MARK: - The whole profile

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
}
