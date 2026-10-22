import Foundation
import FoundationModelsRouterTestSupport
import HuggingFace
import Testing

@testable import FoundationModelsRouter

/// Exercises ``HuggingFaceMetadataSource`` against a stubbed `URLSession`.
///
/// ``HuggingFaceMetadataSource`` is the live ``MetadataSource``; this suite
/// covers its pure routing logic (URL construction, the token header, and
/// mapping an HTTP 404 to `configJSON == nil` vs. surfacing other
/// responses/errors) without any real network access.
///
/// Tests run serialized because every test installs its handler for the one
/// host ``endpoint`` names, and ``StubURLProtocol`` keeps one handler for each
/// host.
@Suite("HuggingFaceMetadataSource", .serialized)
struct HuggingFaceMetadataSourceTests {
    /// A fake Hub origin.
    ///
    /// Every request is intercepted by ``StubURLProtocol``, so no real
    /// DNS/network resolution of this host ever happens.
    private static let endpoint = URL(string: "https://hf.example.test")!

    /// The host the stub answers for ``endpoint``.
    private static var host: String { endpoint.host()! }

    /// The token of the tests that give a fixed token provider.
    private static let token = "t"

    /// The number of GETs of one fetch: `config.json` and the tree listing.
    private static let requestsPerFetch = 2

    /// Builds a source over a stub session.
    ///
    /// - Parameter tokenProvider: The token provider of the source. The
    ///   default `.none` sends no token, so no test reads the token of the
    ///   user that runs it.
    private static func makeSource(tokenProvider: TokenProvider = .none) -> HuggingFaceMetadataSource {
        HuggingFaceMetadataSource(
            endpoint: Self.endpoint, session: StubURLProtocol.makeSession(), tokenProvider: tokenProvider)
    }

    @Test("a source with a fixed token sends Authorization: Bearer <token> on each GET")
    func fixedTokenSendsBearerHeaderOnEachRequest() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install(forHost: Self.host) { request in
            recorder.record(request)
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        _ = try await Self.makeSource(tokenProvider: .fixed(token: Self.token))
            .fetchRawMetadata(repo: "org/model", revision: nil)

        let headers = recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == Array(repeating: "Bearer \(Self.token)", count: Self.requestsPerFetch))
    }

    @Test("a source with no token sends no Authorization header")
    func noTokenSendsNoAuthorizationHeader() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install(forHost: Self.host) { request in
            recorder.record(request)
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        _ = try await Self.makeSource(tokenProvider: .none).fetchRawMetadata(repo: "org/model", revision: nil)

        let headers = recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(headers == Array(repeating: nil, count: Self.requestsPerFetch))
    }

    @Test("a 404 for config.json yields a nil configJSON with treeJSON still populated")
    func missingConfigJSONYieldsNilConfigJSON() async throws {
        let treeJSON = Data("[]".utf8)
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 404), Data())
            }
            return (Self.response(for: request.url!, statusCode: 200), treeJSON)
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.configJSON == nil)
        #expect(raw.treeJSON == treeJSON)
    }

    @Test("a 200 for config.json populates configJSON with the response bytes")
    func presentConfigJSONPopulatesConfigJSON() async throws {
        let configJSON = Data("""
            {"num_hidden_layers": 4, "max_position_embeddings": 8192}
            """.utf8)
        let treeJSON = Data("[]".utf8)
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 200), configJSON)
            }
            return (Self.response(for: request.url!, statusCode: 200), treeJSON)
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.configJSON == configJSON)
        #expect(raw.treeJSON == treeJSON)
    }

    @Test("requested URLs match the expected shape with the revision ?? \"main\" fallback applied")
    func requestedURLsUseDefaultRevisionFallback() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install(forHost: Self.host) { request in
            recorder.record(request)
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        _ = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        let urls = recorder.urls.map(\.absoluteString)
        #expect(urls.contains("https://hf.example.test/org/model/resolve/main/config.json"))
        #expect(urls.contains("https://hf.example.test/api/models/org/model/tree/main"))
    }

    @Test("requested URLs pin the given revision instead of defaulting to main")
    func requestedURLsUseGivenRevision() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.install(forHost: Self.host) { request in
            recorder.record(request)
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        _ = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: "v2")

        let urls = recorder.urls.map(\.absoluteString)
        #expect(urls.contains("https://hf.example.test/org/model/resolve/v2/config.json"))
        #expect(urls.contains("https://hf.example.test/api/models/org/model/tree/v2"))
    }

    @Test("a non-404 HTTP status for config.json is returned as data, not swallowed as absent")
    func non404HTTPStatusIsNotTreatedAsAbsent() async throws {
        let errorBody = Data("internal error".utf8)
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 500), errorBody)
            }
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.configJSON == errorBody)
    }

    @Test("a 404 HTTP status for tree.json is returned as data, since only config.json maps 404 to absent")
    func tree404HTTPStatusIsReturnedAsData() async throws {
        let treeBody = Data("not found".utf8)
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 200), Data("{}".utf8))
            }
            return (Self.response(for: request.url!, statusCode: 404), treeBody)
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.treeJSON == treeBody)
    }

    @Test("a 500 HTTP status for tree.json is returned as data, not swallowed as absent")
    func tree500HTTPStatusIsReturnedAsData() async throws {
        let treeBody = Data("internal error".utf8)
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 200), Data("{}".utf8))
            }
            return (Self.response(for: request.url!, statusCode: 500), treeBody)
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.treeJSON == treeBody)
    }

    @Test("a thrown transport error on the config.json fetch propagates from fetchRawMetadata")
    func thrownTransportErrorOnConfigFetchPropagates() async throws {
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                throw URLError(.notConnectedToInternet)
            }
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        await #expect(throws: URLError.self) {
            _ = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)
        }
    }

    @Test("a thrown transport error on the tree fetch propagates from fetchRawMetadata")
    func thrownTransportErrorOnTreeFetchPropagates() async throws {
        StubURLProtocol.install(forHost: Self.host) { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 200), Data("{}".utf8))
            }
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: URLError.self) {
            _ = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)
        }
    }

    /// Builds a canned `HTTPURLResponse` for a status code.
    ///
    /// Defaults the headers/protocol fields the tests don't care about.
    private static func response(for url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
