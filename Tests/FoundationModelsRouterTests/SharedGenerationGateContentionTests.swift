import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^trwcs63: two sessions over one shared pool entry contend
/// for that entry's one generation gate.
///
/// The consumer's own configuration is a single resolved profile whose
/// `standard` and `flash` name one model. The two refs are equal, so the
/// router pools both slots onto one entry, and every handle built over that
/// entry carries the entry's one ``RoutedModel/generationGate``. That is the
/// object graph ``Router/resolve(profile:reporting:)`` builds, and it is the
/// only object graph a consumer who resolves can obtain. It is also the graph
/// the nested-generation deadlock was measured on.
///
/// A hand-built handle is a different graph. `RoutedModel`'s initializer mints
/// a fresh gate when its `generationGate` argument is `nil`, so two hand-built
/// handles over one container hold two gates and can never contend. Six gated
/// suites build `standard` and `flash` that way over one container and pass no
/// gate: `SessionTreeRestorationIntegrationTests`,
/// `LanguageModelSessionBackendTests`,
/// `TranscriptReconstructionIntegrationTests`, `RealToolTurnComparisonTests`,
/// `CompactionRoundTripIntegrationTests` and `RecordingHandleIntegrationTests`.
/// Those six are **defective**, not correct: the production path resolves and
/// nothing else, and only the resolved graph deadlocked. A hand-built pair
/// tests a configuration the resolver never produces. The public initializer
/// that makes that pair reachable has its own card, ^fmet68k; this suite only
/// records the finding.
///
/// Everything runs against stubs -- a stub loader, a container that reports
/// what is concurrently inside it, and a latch a test opens -- so the suite
/// needs no network and no GPU, and it waits on no clock.
@Suite("Generation gate contention over one shared pool entry")
struct SharedGenerationGateContentionTests {
    // MARK: - Concurrency-observing container

    /// Counts how many model calls are inside the container at one time, so a
    /// test can say whether two generations overlapped without a sleep.
    private actor GenerationObserver {
        /// How many calls are inside the container right now.
        private var active = 0

        /// The most calls that were ever inside the container at one time.
        private(set) var maximumActive = 0

        /// Records one call entering the container.
        func enter() {
            active += 1
            maximumActive = max(maximumActive, active)
        }

        /// Records one call leaving the container.
        func exit() {
            active -= 1
        }
    }

    /// A backend that reports its own entry and exit to a ``GenerationObserver``
    /// and stays inside its model call until a latch opens.
    ///
    /// Holding the call open is what makes the gate observable: a turn keeps
    /// the container's one generation permit for as long as its model call
    /// runs, so a second turn either parks on that permit or proves it never
    /// had to.
    ///
    /// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
    /// owning session drives one backend method at a time, and the observer it
    /// reports to is an actor.
    private final class ObservingSessionBackend: LanguageModelSessionBackend, @unchecked Sendable {
        /// The prefix an answer opens with, so a test can tell one turn's
        /// answer from another's.
        static let answerPrefix = "answered: "

        /// The observer this backend reports its own entry and exit to.
        private let observer: GenerationObserver

        /// The latch a call stays inside the container until a test opens.
        private let latch: RunLatch

        init(observer: GenerationObserver, latch: RunLatch) {
            self.observer = observer
            self.latch = latch
        }

        func respond(to prompt: String, maxTokens: Int?) async throws -> String {
            await observer.enter()
            await latch.waitUntilOpen()
            await observer.exit()
            return Self.answerPrefix + prompt
        }

        func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(Self.answerPrefix + prompt)
                continuation.finish()
            }
        }

        func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
            try await respond(to: prompt, maxTokens: maxTokens)
        }

        func makeFork() -> any LanguageModelSessionBackend { self }

        func transcriptEntries() -> [Transcript.Entry] { [] }

        func usageTokenCounts() -> (input: Int, output: Int)? { nil }
    }

    /// Vends one ``ObservingSessionBackend`` per session, all reporting to one
    /// observer and all held by one latch.
    private struct ObservingLLMContainer: LoadedLLMContainer {
        /// The observer every vended backend reports to.
        let observer: GenerationObserver

        /// The latch every vended backend stays inside its model call until.
        let latch: RunLatch

        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            ObservingSessionBackend(observer: observer, latch: latch)
        }

        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            ObservingSessionBackend(observer: observer, latch: latch)
        }
    }

    // MARK: - Constants

    /// The one model both generation slots name, so the two slots carry one
    /// ``ResidencyKey`` and pool onto one entry -- the consumer's own shape,
    /// where the standard and the flash model are the same model.
    private static let sharedRef: ModelRef = "org/shared-llm"

    /// The prompt the first turn is given.
    private static let firstPrompt = "first"

    /// The prompt the second turn is given.
    private static let secondPrompt = "second"

    // MARK: - Fixtures

    /// Builds a router over `container` and resolves a profile whose standard
    /// and flash slots both name ``sharedRef``.
    ///
    /// - Parameters:
    ///   - container: The stub container every vended session's backend comes
    ///     from.
    ///   - dir: The temporary directory the router caches and records under.
    /// - Returns: The router and the profile it resolved, both of which the
    ///   caller has to keep alive for the length of the test.
    private static func makeSharedEntryProfile(
        container: any LoadedLLMContainer, dir: URL
    ) async throws -> (router: Router, profile: LanguageModelProfile) {
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let definition = ProfileDefinition(
            name: "shared-entry",
            description: "one model for both generation slots",
            standard: [sharedRef],
            flash: [sharedRef],
            embedding: ["org/shared-embedder"]
        )
        let profile = try await router.resolve(profile: definition, reporting: ResolutionProgress())
        return (router, profile)
    }

    /// Builds a profile whose standard and flash handles are constructed by
    /// hand over `container`, each with no `generationGate` argument.
    ///
    /// This is the shape the six gated suites named in this suite's own
    /// documentation build. It exists here as the control for
    /// ``twoHandBuiltHandlesOverOneContainerNeverContend()``, and nowhere else.
    ///
    /// - Parameters:
    ///   - container: The one container both generation handles wrap.
    ///   - router: The router the profile reports its residency to. Nothing is
    ///     resolved through it, so it owns no residency for this profile.
    /// - Returns: The hand-built profile.
    private static func makeHandBuiltProfile(
        container: any LoadedLLMContainer, router: Router
    ) -> LanguageModelProfile {
        let recorder = InMemoryRecorder()
        func resolution(_ slot: ModelSlot) -> SlotResolution {
            SlotResolution(slot: slot, remainingBudgetBytes: 0, chosen: sharedRef, considered: [])
        }
        func handle(_ slot: ModelSlot) -> RoutedLLM {
            RoutedLLM(
                slot: slot,
                chosen: sharedRef,
                footprintBytes: 0,
                resolution: resolution(slot),
                container: container,
                routerId: router.id,
                recorder: recorder
            )
        }
        return LanguageModelProfile(
            definitionName: "hand-built",
            standard: handle(.standard),
            flash: handle(.flash),
            embedding: RoutedEmbedder(
                slot: .embedding,
                chosen: sharedRef,
                footprintBytes: 0,
                resolution: resolution(.embedding),
                container: StubEmbeddingContainer(dimension: RouterTestFixtures.stubDimension),
                routerId: router.id,
                recorder: recorder
            ),
            router: router,
            residencyToken: .generate()
        )
    }

    /// The answer ``ObservingSessionBackend`` gives to `prompt`.
    ///
    /// - Parameter prompt: The prompt a turn was given.
    /// - Returns: The expected answer text.
    private static func answer(to prompt: String) -> String {
        ObservingSessionBackend.answerPrefix + prompt
    }

    // MARK: - The gate a resolve vends

    @Test("a resolve that pools both generation slots onto one entry gives the two handles one gate")
    @MainActor
    func poolingBothGenerationSlotsOntoOneEntryGivesOneGate() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: GenerationObserver(), latch: latch)
        let resolved = try await Self.makeSharedEntryProfile(container: container, dir: dir)

        // Identity, not equality: only one gate instance can serialize the one
        // resident container, and a second pool entry would mint a second.
        #expect(resolved.profile.standard.generationGate === resolved.profile.flash.generationGate)

        await latch.open()
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions over one shared pool entry contend for that entry's one generation gate")
    @MainActor
    func twoSessionsOverOneSharedPoolEntryContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = GenerationObserver()
        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: observer, latch: latch)
        let resolved = try await Self.makeSharedEntryProfile(container: container, dir: dir)
        let gate = resolved.profile.standard.generationGate

        // One session from each generation handle, which is what a consumer
        // holding a resolved profile has.
        let holder = resolved.profile.standard.makeSession()
        let waiter = resolved.profile.flash.makeSession()

        // The holder's turn takes the entry's one permit and stays inside its
        // model call until the latch opens.
        let holderTurn = Task { try await holder.respond(to: Self.firstPrompt) }
        #expect(
            await BoundedWait.conditionReached("the standard session's turn taking the one permit") {
                gate.availablePermits == 0
            })

        // The flash session's turn now parks in `beginTurn()`, on the very
        // same gate. This is the contention: two handles, one entry, one gate.
        let waiterTurn = Task { try await waiter.respond(to: Self.secondPrompt) }
        #expect(
            await BoundedWait.conditionReached("the flash session's turn parking on the shared gate") {
                gate.waiterCount == 1
            })

        // The parked turn never reached the container, so one generation is in
        // flight rather than two.
        #expect(await observer.maximumActive == 1)

        await latch.open()
        #expect(try await holderTurn.value == Self.answer(to: Self.firstPrompt))
        #expect(try await waiterTurn.value == Self.answer(to: Self.secondPrompt))
        #expect(await observer.maximumActive == 1)
        #expect(gate.availablePermits == 1)
        #expect(gate.waiterCount == 0)
        withExtendedLifetime(resolved) {}
    }

    // MARK: - The control

    /// The control demonstrates that two gates over one container permit
    /// concurrent generation, which is the condition the gate exists to
    /// prevent. It passes today, and it must stop passing when the initializer
    /// is fixed.
    ///
    /// Read the assertion that way. "Hand-built handles do not contend" is not
    /// a property to keep; it is the second defect, and card ^fmet68k carries
    /// the fix. Without this control the contention test above proves only
    /// that a gate serializes -- it cannot show that the resolved graph and the
    /// hand-built graph differ, which is the whole reason the six gated suites
    /// could not have caught the deadlock.
    @Test("two hand-built handles over one container never contend, because each mints a gate of its own")
    @MainActor
    func twoHandBuiltHandlesOverOneContainerNeverContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = GenerationObserver()
        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: observer, latch: latch)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        let profile = Self.makeHandBuiltProfile(container: container, router: router)

        #expect(profile.standard.generationGate !== profile.flash.generationGate)

        let first = profile.standard.makeSession()
        let second = profile.flash.makeSession()
        let firstTurn = Task { try await first.respond(to: Self.firstPrompt) }
        let secondTurn = Task { try await second.respond(to: Self.secondPrompt) }

        // Two generations are inside the one resident container at once. The
        // gate exists to make this impossible, and two gates let it happen.
        #expect(
            await BoundedWait.conditionReached("both turns inside the one container at once") {
                await observer.maximumActive == 2
            })

        await latch.open()
        #expect(try await firstTurn.value == Self.answer(to: Self.firstPrompt))
        #expect(try await secondTurn.value == Self.answer(to: Self.secondPrompt))
        withExtendedLifetime(profile) {}
    }
}
