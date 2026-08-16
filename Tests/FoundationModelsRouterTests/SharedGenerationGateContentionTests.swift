import Foundation
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
///
/// No test here takes the main actor, and none may. Nothing in the suite reads
/// or writes main-actor state. A body that took the main actor would have to
/// get it again after each `await`, and it would queue behind every other
/// `@MainActor` test in this target. That cost is large: measured inside the
/// full run, one such resume took 1.28 seconds, and
/// ``twoSessionsOverOneSharedPoolEntryContend()`` took 4.9 seconds for a body
/// that does 5 milliseconds of work. Off the main actor the same test takes
/// 1.0 second, almost all of it the resolve.
@Suite("Generation gate contention over one shared pool entry")
struct SharedGenerationGateContentionTests {
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

    // MARK: - The gate a resolve vends

    @Test("a resolve that pools both generation slots onto one entry gives the two handles one gate")
    func poolingBothGenerationSlotsOntoOneEntryGivesOneGate() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: ConcurrencyPeakObserver(), latch: latch)
        let resolved = try await Self.makeSharedEntryProfile(container: container, dir: dir)

        // Identity, not equality: only one gate instance can serialize the one
        // resident container, and a second pool entry would mint a second.
        #expect(resolved.profile.standard.generationGate === resolved.profile.flash.generationGate)

        await latch.open()
        withExtendedLifetime(resolved) {}
    }

    @Test("two sessions over one shared pool entry contend for that entry's one generation gate")
    func twoSessionsOverOneSharedPoolEntryContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = ConcurrencyPeakObserver()
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

        // Wait for the model call as well, and not for the permit alone.
        // `beginTurn()` takes the permit before it calls the backend, so a
        // permit count of zero does not yet show that the holder is inside the
        // container. The peak reading below is only a proof about the flash
        // session if the standard session is already in the container, and a
        // reading taken too early sees zero for the holder's own call.
        #expect(
            await BoundedWait.conditionReached("the standard session's turn reaching the container") {
                await observer.maximumActive == 1
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
        #expect(try await holderTurn.value == ObservingSessionBackend.answer(to: Self.firstPrompt))
        #expect(try await waiterTurn.value == ObservingSessionBackend.answer(to: Self.secondPrompt))
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
    func twoHandBuiltHandlesOverOneContainerNeverContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = ConcurrencyPeakObserver()
        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: observer, latch: latch)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        // No gate: each handle then mints one of its own. That is the shape the
        // six gated suites build, and the hazard this control records.
        let profile = HandBuiltProfileFixtures.makeProfile(
            definitionName: "hand-built",
            chosen: Self.sharedRef,
            container: container,
            router: router,
            generationGate: nil
        )

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
        #expect(try await firstTurn.value == ObservingSessionBackend.answer(to: Self.firstPrompt))
        #expect(try await secondTurn.value == ObservingSessionBackend.answer(to: Self.secondPrompt))
        withExtendedLifetime(profile) {}
    }
}
