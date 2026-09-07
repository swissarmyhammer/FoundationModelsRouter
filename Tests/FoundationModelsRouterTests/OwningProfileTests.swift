import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the weak back-reference a ``RoutedModel`` keeps to the
/// ``LanguageModelProfile`` that owns it.
///
/// The slot has two properties, and this suite holds it to both.
///
/// It is filled after the handle's initializer, because
/// ``Router/resolve(profile:reporting:)`` builds the three handles first and
/// passes them into ``LanguageModelProfile/init(definitionName:standard:flash:embedding:residencyToken:)``
/// afterwards. A handle therefore reports `nil` until a profile registers
/// itself.
///
/// It is weak, because the profile holds the three handles strongly. A strong
/// back-reference would make a cycle: neither the profile nor its handles could
/// ever be deallocated, so the ``ResidencyHold`` those handles share would keep
/// its last reference forever, and `ResidencyHold.deinit`, which gives the
/// residency back to the router, would never run. The profile itself has no
/// `deinit` at all. A handle therefore reports `nil` again once ARC deallocates
/// the profile.
///
/// Everything runs against stubs -- a stub loader over an undriven container --
/// so the suite needs no network and no GPU, and it waits on no clock. The
/// release test is deterministic for the same reason: the weak slot clears as
/// ARC deallocates the profile, and no residency work follows that. A
/// hand-built profile resolves nothing and therefore carries no
/// ``ResidencyHold``, and a real hold refers to the router and the token only,
/// never to the profile, so no assertion here depends on when a release runs.
@Suite("Owning profile back-reference")
struct OwningProfileTests {
    // MARK: - Constants

    /// The model reference every hand-built slot names.
    private static let chosenRef: ModelRef = "org/owning-profile-llm"

    /// The definition name the hand-built profile reports.
    private static let definitionName = "owning-profile"

    // MARK: - Fixtures

    /// Runs `body` over a router built on a stub loader and a fresh temp cache
    /// directory, and removes the directory afterwards.
    ///
    /// - Parameter body: The test body, given the router.
    private static func withStubRouter(_ body: (Router) throws -> Void) rethrows {
        let dir = RouterTestFixtures.makeTempDir(prefix: "OwningProfileTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            loader: StubModelLoader(
                container: UndrivenLanguageModelContainer(),
                dimension: RouterTestFixtures.stubDimension
            )
        )
        try body(router)
    }

    /// Builds one bare generation handle, with no profile over it.
    ///
    /// ``HandBuiltProfileFixtures`` builds a handle of this shape too, but its
    /// helper is `private` on purpose: it mints one ``ResidentModelGates`` set
    /// for the one container and hands it to both generation handles, which is
    /// the one-gate rule card ^fmet68k closed a defect to establish. A suite
    /// that could reach the helper could mint a second gate set over an
    /// already-resident container. So this suite calls ``RoutedLLM``'s
    /// initializer itself, and takes no handle out of that factory.
    ///
    /// A hand-built slot resolves nothing, so it carries no footprint and
    /// leaves no budget.
    ///
    /// - Parameter router: The router the handle stamps its recording root from.
    /// - Returns: The bare handle.
    private static func makeBareHandle(router: Router) -> RoutedLLM {
        RoutedLLM(
            slot: .standard,
            chosen: chosenRef,
            footprintBytes: 0,
            resolution: SlotResolution(
                slot: .standard,
                remainingBudgetBytes: 0,
                chosen: chosenRef,
                considered: []
            ),
            container: UndrivenLanguageModelContainer(),
            routerId: router.id,
            recorder: InMemoryRecorder(),
            gates: ResidentModelGates(maxConcurrentForks: defaultMaxConcurrentForks)
        )
    }

    /// Builds a profile whose three slots all wrap one undriven container.
    ///
    /// - Parameter router: The router the profile reports its residency to.
    /// - Returns: The hand-built profile.
    private static func makeProfile(router: Router) -> LanguageModelProfile {
        HandBuiltProfileFixtures.makeProfile(
            definitionName: definitionName,
            chosen: chosenRef,
            container: UndrivenLanguageModelContainer(),
            router: router
        )
    }

    // MARK: - Tests

    @Test("a handle reports no owning profile until a profile registers itself")
    func handleReportsNilBeforeRegistration() {
        Self.withStubRouter { router in
            let handle = Self.makeBareHandle(router: router)

            #expect(handle.owningProfile == nil)
        }
    }

    @Test("the profile's initializer registers the profile on all three handles")
    func profileInitRegistersItselfOnAllThreeHandles() {
        Self.withStubRouter { router in
            let profile = Self.makeProfile(router: router)

            #expect(profile.standard.owningProfile === profile)
            #expect(profile.flash.owningProfile === profile)
            #expect(profile.embedding.owningProfile === profile)
        }
    }

    @Test("a handle reports no owning profile again once the profile is released")
    func handleDropsProfileWhenProfileIsReleased() throws {
        try Self.withStubRouter { router in
            var profile: LanguageModelProfile? = Self.makeProfile(router: router)
            let standard = try #require(profile?.standard)
            #expect(standard.owningProfile === profile)

            profile = nil

            #expect(standard.owningProfile == nil)
        }
    }
}
