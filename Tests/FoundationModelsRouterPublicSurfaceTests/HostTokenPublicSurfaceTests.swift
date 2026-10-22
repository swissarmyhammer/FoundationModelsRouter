import Foundation
import FoundationModelsRouterTestSupport
import HuggingFace
import Testing

import FoundationModelsRouter

/// Holds the Hugging Face token of the host to the access level that a host
/// outside this package needs: a host with its own home gives one
/// `TokenProvider` to the live loader, for each download, and to the
/// metadata source, for each sizing request. The host then does not depend on
/// the token in the Hugging Face folder of the user.
///
/// The import is plain, with no `@testable`, so an init that loses `public`
/// or its `tokenProvider` parameter stops this file from compiling before a
/// single test runs. Each test answers on a host of its own, so the tests run
/// in parallel with each other and with the unit suites of the stub.
@Suite("Host token over a plain import")
struct HostTokenPublicSurfaceTests {
    /// The token that the provider of the host reads.
    private static let token = "host-token"

    /// The number of GETs of one metadata fetch: `config.json` and the tree
    /// listing.
    private static let requestsPerFetch = 2

    @Test("a host gives one token provider to downloads and to sizing, and each sizing GET sends its token")
    func oneProviderServesDownloadsAndSizing() async throws {
        let provider: TokenProvider = .custom { Self.token }
        let recorder = RequestRecorder()
        let endpoint = Self.makeEndpoint(recordingInto: recorder)

        _ = LiveModelLoader(tokenProvider: provider)
        let source = HuggingFaceMetadataSource(
            endpoint: endpoint, session: StubURLProtocol.makeSession(), tokenProvider: provider)
        _ = try await source.fetchRawMetadata(repo: "org/model", revision: nil)

        let headers = recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == Array(repeating: "Bearer \(Self.token)", count: Self.requestsPerFetch))
    }

    @Test("a host that gives the .none provider sends no token on a sizing GET")
    func noneProviderSendsNoToken() async throws {
        let recorder = RequestRecorder()
        let endpoint = Self.makeEndpoint(recordingInto: recorder)

        let source = HuggingFaceMetadataSource(
            endpoint: endpoint, session: StubURLProtocol.makeSession(), tokenProvider: .none)
        _ = try await source.fetchRawMetadata(repo: "org/model", revision: nil)

        let headers = recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == Array(repeating: nil, count: Self.requestsPerFetch))
    }

    /// Makes a fake Hub origin on a host of its own, and installs a stub
    /// handler for it that records each request into `recorder` and answers
    /// with an empty listing.
    ///
    /// - Parameter recorder: The recorder of the requests to the origin.
    /// - Returns: The origin.
    private static func makeEndpoint(recordingInto recorder: RequestRecorder) -> URL {
        let host = "\(UUID().uuidString.lowercased()).hub.example.test"
        StubURLProtocol.install(forHost: host) { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("[]".utf8))
        }
        return URL(string: "https://\(host)")!
    }
}
