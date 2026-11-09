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
        #expect(urls.contains("https://hf.example.test/api/models/org/model/tree/main?recursive=true"))
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
        #expect(urls.contains("https://hf.example.test/api/models/org/model/tree/v2?recursive=true"))
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

    /// The path of the GGUF file the range tests read.
    private static let ggufPath = "Q4_K_M/model-Q4_K_M.gguf"

    /// The bytes of the whole file the range tests read.
    private static let fileBytes = Data((0..<64).map { UInt8($0) })

    /// The range the range tests read.
    private static let readRange = 8..<24

    /// The status of a response that holds a range of the file.
    private static let partialContentStatus = 206

    /// Installs a handler that records each request and answers it with
    /// `status` and `body`.
    ///
    /// - Parameters:
    ///   - status: The HTTP status of each response.
    ///   - body: The body of each response.
    /// - Returns: The recorder of the requests.
    private static func installRecording(status: Int, body: Data) -> RequestRecorder {
        let recorder = RequestRecorder()
        StubURLProtocol.install(forHost: host) { request in
            recorder.record(request)
            return (response(for: request.url!, statusCode: status), body)
        }
        return recorder
    }

    /// Reads ``readRange`` of ``ggufPath`` through a stub source.
    ///
    /// - Parameter tokenProvider: The token provider of the source.
    /// - Returns: The bytes.
    /// - Throws: The error of the read.
    private static func readFileRange(tokenProvider: TokenProvider = .none) async throws -> Data {
        try await makeSource(tokenProvider: tokenProvider)
            .fetchFileBytes(repo: "org/model", revision: nil, path: ggufPath, range: readRange)
    }

    @Test("a file range is read from the resolve URL of the file at the revision")
    func fileRangeUsesResolveURL() async throws {
        let recorder = Self.installRecording(status: Self.partialContentStatus, body: Data())

        _ = try await Self.readFileRange()

        #expect(recorder.urls.map(\.absoluteString) == ["https://hf.example.test/org/model/resolve/main/\(Self.ggufPath)"])
    }

    @Test("a file range is asked for with an inclusive HTTP Range header")
    func fileRangeSendsRangeHeader() async throws {
        let recorder = Self.installRecording(status: Self.partialContentStatus, body: Data())

        _ = try await Self.readFileRange()

        #expect(recorder.requests.map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=8-23"])
    }

    @Test("a file range read sends the token of the provider")
    func fileRangeSendsToken() async throws {
        let recorder = Self.installRecording(status: Self.partialContentStatus, body: Data())

        _ = try await Self.readFileRange(tokenProvider: .fixed(token: Self.token))

        #expect(recorder.requests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer \(Self.token)"])
    }

    @Test("a 206 response gives its body as the bytes of the range")
    func partialContentGivesBody() async throws {
        let body = Self.fileBytes.subdata(in: Self.readRange)
        _ = Self.installRecording(status: Self.partialContentStatus, body: body)

        #expect(try await Self.readFileRange() == body)
    }

    @Test("a 200 response from a server that ignored the range gives only the bytes of the range")
    func fullContentIsCutToTheRange() async throws {
        _ = Self.installRecording(status: 200, body: Self.fileBytes)

        #expect(try await Self.readFileRange() == Self.fileBytes.subdata(in: Self.readRange))
    }

    @Test("a 404 for a file range is an error, not bytes of a header")
    func missingFileIsAnError() async throws {
        _ = Self.installRecording(status: 404, body: Data("not found".utf8))

        await #expect(throws: RepoMetadataError.self) { _ = try await Self.readFileRange() }
    }

    @Test("a 416 for a range past the end of the file gives no bytes")
    func rangePastTheEndGivesNoBytes() async throws {
        _ = Self.installRecording(status: 416, body: Data())

        #expect(try await Self.readFileRange().isEmpty)
    }

    /// Builds a canned `HTTPURLResponse` for a status code.
    ///
    /// Defaults the headers/protocol fields the tests don't care about.
    private static func response(for url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}
