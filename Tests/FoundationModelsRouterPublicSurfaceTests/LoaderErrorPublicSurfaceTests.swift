import Foundation
import Testing

import FoundationModelsRouter

/// Holds the errors that the public loaders throw to the access level a
/// consumer outside this package needs (task ^z5d5k5f): `ModelLoaderError`,
/// which each load of `UnconfiguredModelLoader` throws, and
/// `LiveModelLoaderError`, which `LiveModelLoader.loadLLM` throws when its
/// model loader gives no `MLXLanguageModel`.
///
/// The import is plain, with no `@testable`, and no file of this target
/// imports the library `@testable`, so the compiler is the first assertion
/// here: an error type that loses `public` stops this file from compiling
/// before a single test runs. The body then catches the error of a load and
/// reads it back through the public types — the catch that a caller makes.
@Suite("Loader errors over a plain import")
struct LoaderErrorPublicSurfaceTests {
    /// The model that each load of this suite names.
    private static let ref: ModelRef = "org/unconfigured-a"

    /// The context that each load of this suite names. The unconfigured
    /// loader throws before it reads it.
    private static let context = 4_096

    /// Tells if `error` is a failure of a load of `LiveModelLoader`. A caller
    /// outside the package makes this test to show a message about a model
    /// that is not an `MLXLanguageModel`.
    ///
    /// - Parameter error: The error that a load threw.
    /// - Returns: `true` when `error` is a `LiveModelLoaderError`.
    private static func isLiveLoaderFailure(_ error: any Error) -> Bool {
        guard let failure = error as? LiveModelLoaderError else { return false }
        switch failure {
        case .notAnMLXLanguageModel: return true
        }
    }

    @Test("a plain import catches the error of an unconfigured load, which is not a live-loader failure")
    func catchesTheErrorOfAnUnconfiguredLoad() async throws {
        let error = await #expect(throws: ModelLoaderError.notConfigured) {
            _ = try await UnconfiguredModelLoader().loadLLM(
                ref: Self.ref, slot: .standard, context: Self.context, reporting: { _ in })
        }
        let thrown: any Error = try #require(error)
        #expect(!Self.isLiveLoaderFailure(thrown))
    }
}
