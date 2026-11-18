import Foundation
import Testing

import FoundationModelsRouter

/// Holds the fit estimate of a router
/// (``Router/estimateFit(of:minimumContextTokens:)`` and
/// ``ProfileFitEstimate``) to the access level that a host needs: a settings
/// pane reads each field of the estimate of each profile before the user
/// selects one.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs. The router has
/// the default loader, which loads no model, and a metadata source that
/// refuses each fetch, so the test reads no network.
@Suite("Profile fit estimate over a plain import")
struct ProfileFitEstimatePublicSurfaceTests {
    /// The temp-directory prefix of the cache directory of the router, so a
    /// leaked directory names this suite.
    private static let tempDirPrefix = "ProfileFitEstimatePublicSurfaceTests"

    /// The GPU working set that the probe reports: the budget of the
    /// estimate.
    private static let budgetBytes: Int64 = 48 << 30

    /// A ``MachineProbe`` whose working set is ``budgetBytes``.
    private struct BudgetProbe: MachineProbe {
        let chip = "Apple Test"
        let totalRAM = ProfileFitEstimatePublicSurfaceTests.budgetBytes
        let recommendedMaxWorkingSetSize = ProfileFitEstimatePublicSurfaceTests.budgetBytes
    }

    /// A ``MetadataSource`` that refuses each fetch, so no candidate is
    /// sized.
    private struct RefusingMetadataSource: MetadataSource {
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            throw URLError(.notConnectedToInternet)
        }
    }

    /// The estimate of the default builtin profile by a router whose
    /// metadata source refuses each fetch.
    ///
    /// - Parameter minimumContextTokens: The minimum window of the estimate,
    ///   or `nil` to call the estimate with no minimum argument.
    /// - Returns: The estimate.
    /// - Throws: When the default builtin profile is missing.
    private static func estimateOfDefaultProfile(minimumContextTokens: Int?) async throws -> ProfileFitEstimate {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempDirPrefix)-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = Router(
            cacheDir: dir, probe: BudgetProbe(), metadataSource: RefusingMetadataSource(), pool: ModelPool())
        let profile = try #require(ModelProfiles.named(ModelProfiles.defaultName))
        if let minimumContextTokens {
            return await router.estimateFit(of: profile, minimumContextTokens: minimumContextTokens)
        }
        return await router.estimateFit(of: profile)
    }

    @Test("a host reads each field of the estimate of a builtin profile")
    func hostReadsEachField() async throws {
        let estimate = try await Self.estimateOfDefaultProfile(minimumContextTokens: nil)

        #expect(
            !estimate.fits && estimate.requiredBytes == nil && estimate.contextTokens == nil
                && estimate.budgetBytes == Self.budgetBytes && estimate.chosen.isEmpty && estimate.failure != nil)
    }

    @Test("a host gives the default minimum window to the estimate")
    func hostGivesTheDefaultMinimumWindow() async throws {
        let estimate = try await Self.estimateOfDefaultProfile(
            minimumContextTokens: ProfileFitEstimate.defaultMinimumContextTokens)

        #expect(estimate.budgetBytes == Self.budgetBytes)
    }
}
