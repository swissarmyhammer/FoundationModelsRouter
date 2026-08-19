import Foundation
import FoundationModelsRouterTestSupport
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
/// A hand-built handle used to be a different graph. `RoutedModel`'s public
/// initializer minted a fresh gate when its `generationGate` argument was
/// `nil`, so two hand-built handles over one container held two gates, could
/// never contend, and ran two generations inside the one container at once.
/// Card ^fmet68k closed that: handle construction left the public surface, the
/// gates became one required ``ResidentModelGates`` value with no default, and
/// ``HandBuiltProfileFixtures`` gives both generation handles the one set its
/// container carries. The two graphs no longer differ, and this suite holds
/// them to the same contract -- the resolved pair in
/// ``twoSessionsOverOneSharedPoolEntryContend()`` and the hand-built pair in
/// ``twoHandBuiltHandlesOverOneContainerContend()``, both through the one
/// drill.
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

    /// Runs one turn on `profile.standard` and one on `profile.flash`, and
    /// holds the pair to the one-gate contract.
    ///
    /// The standard turn takes the one permit and stays inside its model call
    /// until the latch opens. The flash turn then parks on the very same gate,
    /// so one generation is in flight over the one container rather than two.
    /// Both turns answer once the latch opens, and the gate is left as it was
    /// found.
    ///
    /// The two graphs a caller can build -- the resolved pair and the
    /// hand-built pair -- go through this one drill, because after card
    /// ^fmet68k they owe the same contract. Writing the drill twice would let
    /// the two copies drift apart, and the whole point is that they do not.
    ///
    /// - Parameters:
    ///   - profile: The profile whose two generation handles wrap one
    ///     container.
    ///   - observer: The peak observer the container reports into.
    ///   - latch: The latch that holds the first turn inside the container.
    private static func expectGenerationsSerialize(
        over profile: LanguageModelProfile,
        observer: ConcurrencyPeakObserver,
        latch: RunLatch
    ) async throws {
        // Identity, not equality: only one gate instance can serialize the one
        // resident container, and a second gate would let both turns in.
        #expect(profile.standard.generationGate === profile.flash.generationGate)
        let gate = profile.standard.generationGate

        let holder = profile.standard.makeSession()
        let waiter = profile.flash.makeSession()

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
        // same gate. This is the contention: two handles, one container, one
        // gate.
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

        // One session from each generation handle, which is what a consumer
        // holding a resolved profile has.
        try await Self.expectGenerationsSerialize(
            over: resolved.profile, observer: observer, latch: latch)

        withExtendedLifetime(resolved) {}
    }

    // MARK: - The control

    /// The control shows that a hand-built graph now serializes exactly as the
    /// resolved graph does: two handles over one container hold one gate, and
    /// one generation only is inside the container at a time.
    ///
    /// Read the assertion that way. This test asserted the opposite until card
    /// ^fmet68k. `RoutedModel`'s public initializer let each handle mint a gate
    /// of its own, so a hand-built pair could never contend and two generations
    /// ran inside one container at once -- the condition the gate exists to
    /// prevent. That was a defect and not a property to keep, and six gated
    /// suites built their profiles that way.
    ///
    /// The control is what proves the fix landed. The contention test above
    /// shows only that a gate serializes; it cannot show that the resolved
    /// graph and the hand-built graph now agree, and that agreement is what the
    /// six gated suites needed to catch the deadlock ^1zt7vyg records.
    @Test("two hand-built handles over one container contend, because both take the container's one gate")
    func twoHandBuiltHandlesOverOneContainerContend() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: "SharedGenerationGateContentionTests")
        defer { try? FileManager.default.removeItem(at: dir) }

        let observer = ConcurrencyPeakObserver()
        let latch = RunLatch()
        let container = ObservingLLMContainer(observer: observer, latch: latch)
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension)
        )
        // No gate argument, and none to give: the factory mints one set for the
        // one container and hands it to both generation handles.
        let profile = HandBuiltProfileFixtures.makeProfile(
            definitionName: "hand-built",
            chosen: Self.sharedRef,
            container: container,
            router: router
        )

        try await Self.expectGenerationsSerialize(
            over: profile, observer: observer, latch: latch)

        withExtendedLifetime(profile) {}
    }
}
