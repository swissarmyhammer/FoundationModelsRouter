import Foundation
import HuggingFace
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Proves that a ``LiveModelLoader`` gives the token provider of the host to
/// the Extras `MLXModelLoader`, so each download sends the token of the host
/// and not the token in the Hugging Face folder of the user.
///
/// No test downloads. Each test reads the token of the `HubClient` that the
/// Extras loader makes for a download.
@Suite("Token provider of the live loader")
struct LiveModelLoaderTokenProviderTests {
    /// The token of the provider that the host gives.
    private static let token = "host-token"

    @Test("a live loader gives its token provider to the Hub client of each download")
    func tokenProviderReachesTheHubClient() async throws {
        let loader = LiveModelLoader(tokenProvider: .fixed(token: Self.token))

        let client = try loader.requireMLXModelLoader().hubClient()

        #expect(await client.bearerToken == Self.token)
    }

    @Test("a live loader with the .none provider sends no token")
    func noneProviderSendsNoToken() async throws {
        let loader = LiveModelLoader(tokenProvider: .none)

        let client = try loader.requireMLXModelLoader().hubClient()

        #expect(await client.bearerToken == nil)
    }
}
