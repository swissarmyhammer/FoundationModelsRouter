import Foundation
import Testing

@testable import FoundationModelsRouter

/// Tests for ``Router/estimateFit(of:)``: the fit estimate that sizes a
/// profile against the machine budget with no admission job, no hold and no
/// load. The stub metadata sources answer each fetch, so no test reads the
/// network.
@Suite("Router fit estimate")
struct EstimateFitTests {
    /// The temp-directory prefix of the cache directory of each test, so a
    /// leaked directory names this suite.
    private static let tempDirPrefix = "EstimateFitTests"

    /// A budget of one byte: no stub model fits it.
    private static let tooSmallBudgetBytes: Int64 = 1

    /// A budget that holds one trio of the stub model and nothing more
    /// (``ResidencyFixtures/oneTrioFootprint``).
    private static let oneTrioBudgetBytes = ResidencyFixtures.oneTrioFootprint + ResidencyFixtures.headroomBufferBytes

    /// The four slots of a profile.
    private static let allSlots: Set<ModelSlot> = [.standard, .flash, .embedding, .decision]

    /// The reason that ``FailingMetadataSource`` gives for each fetch.
    private static let sizingFailureReason = "the stub source refuses each fetch"

    /// A ``MetadataSource`` that refuses each fetch with
    /// ``sizingFailureReason``.
    private struct FailingMetadataSource: MetadataSource {
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            throw RepoMetadataError.metadataUnavailable(EstimateFitTests.sizingFailureReason)
        }
    }

    /// A builtin profile whose decision slot names the candidates of its own
    /// flash slot. The builtin decision candidate is a GGUF file, and the
    /// stub metadata source does not read a GGUF header, so the stub can
    /// size the flash model but not the builtin decision model.
    ///
    /// - Parameter builtin: A profile of ``ModelProfiles/builtin``.
    /// - Returns: The profile with a decision slot that the stub can size.
    private static func stubSizable(_ builtin: ProfileDefinition) -> ProfileDefinition {
        var profile = builtin
        profile.decision = builtin.flash
        return profile
    }

    /// A router over a spying loader and a probe whose budget is
    /// `budgetBytes`, with a fresh pool.
    ///
    /// - Parameters:
    ///   - spy: The spy of each load.
    ///   - budgetBytes: The machine budget.
    ///   - cacheDir: The cache directory of the router.
    /// - Returns: The router.
    private static func makeRouter(spy: LoadSpy = LoadSpy(), budgetBytes: Int64, cacheDir: URL) -> Router {
        ResidencyFixtures.makeRouter(spy: spy, recommendedMaxWorkingSetSize: budgetBytes, cacheDir: cacheDir)
    }

    // MARK: - A fit

    @Test("Each builtin profile fits a large budget", arguments: ModelProfiles.builtin)
    func builtinProfileFitsALargeBudget(builtin: ProfileDefinition) async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        let estimate = await router.estimateFit(of: Self.stubSizable(builtin))

        #expect(estimate.fits)
    }

    @Test("A fit chooses one model for each of the four slots")
    func fitChoosesEachSlot() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(Set(estimate.chosen.keys) == Self.allSlots)
    }

    @Test("A fit requires no more bytes than the budget")
    func fitRequiresNoMoreThanTheBudget() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: Self.oneTrioBudgetBytes, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        let required = try #require(estimate.requiredBytes)
        #expect(required <= estimate.budgetBytes)
    }

    @Test("A fit of the standard profile requires the bytes of one trio")
    func fitRequiresTheTrioBytes() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(estimate.requiredBytes == ResidencyFixtures.oneTrioFootprint)
    }

    // MARK: - No fit

    @Test("A profile does not fit a budget that is too small")
    func tooSmallBudgetDoesNotFit() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: Self.tooSmallBudgetBytes, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(!estimate.fits && estimate.chosen.isEmpty)
    }

    @Test("A profile that does not fit has a failure")
    func noFitHasAFailure() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: Self.tooSmallBudgetBytes, cacheDir: dir)

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(estimate.failure != nil)
    }

    @Test("A sizing error of the metadata source is the reason of the failure")
    func sizingErrorIsTheReason() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(
            cacheDir: dir, recorder: InMemoryRecorder(), probe: RouterTestFixtures.stubProbe,
            metadataSource: FailingMetadataSource(), loader: SpyingModelLoader(
                spy: LoadSpy(), dimension: RouterTestFixtures.stubDimension),
            pool: ModelPool())

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        let failure = try #require(estimate.failure)
        #expect(!estimate.fits && failure.contains(Self.sizingFailureReason))
    }

    @Test("A cancelled estimate does not fit")
    func cancelledEstimateDoesNotFit() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        // The task cancels itself before it asks for the estimate, so the
        // estimate starts in a cancelled task, with no race.
        let estimate = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await router.estimateFit(of: RouterTestFixtures.profile())
        }.value

        #expect(!estimate.fits)
    }

    // MARK: - No load and no pool

    @Test("An estimate calls no loader")
    func estimateCallsNoLoader() async {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let spy = LoadSpy()
        let router = Self.makeRouter(spy: spy, budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        _ = await router.estimateFit(of: RouterTestFixtures.profile())

        let loads = await spy.llmLoads.count + spy.embedderLoads.count
        #expect(loads == 0)
    }

    @Test("An estimate leaves the pool empty")
    func estimateLeavesThePoolEmpty() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: RouterTestFixtures.stubWorkingSet, cacheDir: dir)

        _ = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(try await router.pool.admittedFootprint.resident.isEmpty)
    }

    @Test("A model resident in the pool does not change the budget of an estimate")
    func residentModelDoesNotChangeTheBudget() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Self.makeRouter(budgetBytes: Self.oneTrioBudgetBytes, cacheDir: dir)
        let resident = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())

        let estimate = await router.estimateFit(of: RouterTestFixtures.profile())

        #expect(estimate.budgetBytes == Self.oneTrioBudgetBytes)
        withExtendedLifetime(resident) {}
    }
}
