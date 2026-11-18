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
/// stops this file from compiling before a single test runs. Each router has
/// the default loader, which loads no model, and a metadata source that
/// reads no network.
@Suite("Profile fit estimate over a plain import")
struct ProfileFitEstimatePublicSurfaceTests {
    /// The temp-directory prefix of the cache directory of the router, so a
    /// leaked directory names this suite.
    private static let tempDirPrefix = "ProfileFitEstimatePublicSurfaceTests"

    /// The GPU working set that the probe reports when the test does not
    /// set the budget: the budget of the estimate.
    private static let budgetBytes: Int64 = 48 << 30

    /// The native window of the canned model: much larger than
    /// ``windowUnderTheMinimum``, so the budget, not the model, sets the
    /// window.
    private static let nativeWindow = 131_072

    /// A window under ``ProfileFitEstimate/defaultMinimumContextTokens``.
    private static let windowUnderTheMinimum = 8_192

    /// The default minimum window as the failure of an estimate writes it.
    private static let defaultMinimumText = "32,768"

    /// The canned `config.json` payload behind ``rawMetadata``: a tiny,
    /// valid model config that the router can size.
    private static let configJSON = Data(
        """
        {
            "num_hidden_layers": 2,
            "max_position_embeddings": \(nativeWindow),
            "num_attention_heads": 8,
            "num_key_value_heads": 2,
            "head_dim": 16,
            "hidden_size": 128
        }
        """.utf8)

    /// The canned repo file-tree payload behind ``rawMetadata``: one
    /// weights file that the router can size.
    private static let treeJSON = Data(
        """
        [
            {"type": "file", "path": "model.safetensors", "size": 10000000}
        ]
        """.utf8)

    /// The canned repo metadata that the canned metadata source serves for
    /// each candidate.
    private static var rawMetadata: RawRepoMetadata {
        RawRepoMetadata(configJSON: configJSON, treeJSON: treeJSON)
    }

    /// The one candidate of each slot of the canned profile.
    private static let cannedRef: ModelRef = "org/model"

    /// A ``MachineProbe`` whose working set is the budget of the estimate.
    private struct BudgetProbe: MachineProbe {
        let chip = "Apple Test"
        let totalRAM: Int64
        let recommendedMaxWorkingSetSize: Int64

        /// Creates a probe whose RAM and working set are `budget`.
        ///
        /// - Parameter budget: The bytes of the working set.
        init(budget: Int64) {
            totalRAM = budget
            recommendedMaxWorkingSetSize = budget
        }
    }

    /// A ``MetadataSource`` that refuses each fetch, so no candidate is
    /// sized.
    private struct RefusingMetadataSource: MetadataSource {
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            throw URLError(.notConnectedToInternet)
        }
    }

    /// A ``MetadataSource`` that answers each fetch with ``rawMetadata``.
    private struct CannedMetadataSource: MetadataSource {
        func fetchRawMetadata(repo: String, revision: String?) async throws -> RawRepoMetadata {
            ProfileFitEstimatePublicSurfaceTests.rawMetadata
        }
    }

    /// The canned profile: ``cannedRef`` in each slot.
    ///
    /// - Parameter context: The context of the profile, or `nil` to derive
    ///   the window from the budget.
    /// - Returns: The profile.
    private static func cannedProfile(context: Int?) -> ProfileDefinition {
        ProfileDefinition(
            name: "public-surface",
            description: "one candidate for each slot",
            standard: [cannedRef],
            flash: [cannedRef],
            embedding: [cannedRef],
            decision: [cannedRef],
            context: context)
    }

    /// A router with the default loader over a fresh cache directory.
    ///
    /// - Parameters:
    ///   - budget: The working set of the probe.
    ///   - metadataSource: The metadata source of the router.
    ///   - dir: The cache directory of the router.
    /// - Returns: The router.
    private static func makeRouter(budget: Int64, metadataSource: any MetadataSource, dir: URL) -> Router {
        Router(cacheDir: dir, probe: BudgetProbe(budget: budget), metadataSource: metadataSource, pool: ModelPool())
    }

    /// A fresh cache directory, named with ``tempDirPrefix``.
    private static func makeCacheDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(tempDirPrefix)-\(UUID().uuidString)", isDirectory: true)
    }

    /// The estimate of the default builtin profile by a router whose
    /// metadata source refuses each fetch.
    ///
    /// - Returns: The estimate.
    /// - Throws: When the default builtin profile is missing.
    private static func estimateOfDefaultProfile() async throws -> ProfileFitEstimate {
        let dir = makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let router = makeRouter(budget: budgetBytes, metadataSource: RefusingMetadataSource(), dir: dir)
        let profile = try #require(ModelProfiles.named(ModelProfiles.defaultName))
        return await router.estimateFit(of: profile)
    }

    /// The estimate of the canned profile with a derived window, against
    /// the budget whose largest window is ``windowUnderTheMinimum``.
    ///
    /// The budget is the charge of the canned profile at that explicit
    /// context. The charge grows linearly with the window, so the largest
    /// window that fits the budget is that window.
    ///
    /// - Parameter minimumContextTokens: The minimum window of the estimate.
    /// - Returns: The estimate.
    /// - Throws: When the charge at ``windowUnderTheMinimum`` is missing.
    private static func estimateUnderTheMinimum(minimumContextTokens: Int) async throws -> ProfileFitEstimate {
        let dir = makeCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let measuring = makeRouter(budget: budgetBytes, metadataSource: CannedMetadataSource(), dir: dir)
        let charge = try #require(
            await measuring.estimateFit(of: cannedProfile(context: windowUnderTheMinimum)).requiredBytes)
        let router = makeRouter(budget: charge, metadataSource: CannedMetadataSource(), dir: dir)
        return await router.estimateFit(of: cannedProfile(context: nil), minimumContextTokens: minimumContextTokens)
    }

    @Test("a host reads each field of the estimate of a builtin profile")
    func hostReadsEachField() async throws {
        let estimate = try await Self.estimateOfDefaultProfile()

        #expect(
            !estimate.fits && estimate.requiredBytes == nil && estimate.contextTokens == nil
                && estimate.budgetBytes == Self.budgetBytes && estimate.chosen.isEmpty && estimate.failure != nil)
    }

    @Test("the default minimum window refuses a budget with a smaller window")
    func defaultMinimumRefusesASmallerWindow() async throws {
        let estimate = try await Self.estimateUnderTheMinimum(
            minimumContextTokens: ProfileFitEstimate.defaultMinimumContextTokens)

        #expect(!estimate.fits && estimate.failure?.contains(Self.defaultMinimumText) == true)
    }
}
