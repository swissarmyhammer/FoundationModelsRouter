import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises ``HuggingFaceMetadataSource`` — the live ``MetadataSource`` — against
/// a mocked `URLSession` so its pure routing logic (URL construction and mapping
/// an HTTP 404 to `configJSON == nil` vs. surfacing other responses/errors) is
/// covered without any real network access.
///
/// Tests run serialized because ``MockURLProtocol`` holds a single handler slot
/// shared across the class (`URLSession` instantiates the protocol internally, so
/// there is no per-test instance to hang the handler off of).
@Suite("HuggingFaceMetadataSource", .serialized)
struct HuggingFaceMetadataSourceTests {
    /// A fake Hub origin; every request is intercepted by ``MockURLProtocol``, so
    /// no real DNS/network resolution of this host ever happens.
    private static let endpoint = URL(string: "https://hf.example.test")!

    /// Builds a source over a session whose only protocol is ``MockURLProtocol``.
    private static func makeSource() -> HuggingFaceMetadataSource {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return HuggingFaceMetadataSource(endpoint: Self.endpoint, session: URLSession(configuration: config))
    }

    @Test("a 404 for config.json yields a nil configJSON with treeJSON still populated")
    func missingConfigJSONYieldsNilConfigJSON() async throws {
        let treeJSON = Data("[]".utf8)
        MockURLProtocol.install { request in
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
            {"num_hidden_layers": 4}
            """.utf8)
        let treeJSON = Data("[]".utf8)
        MockURLProtocol.install { request in
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
        MockURLProtocol.install { request in
            recorder.record(request.url!)
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
        MockURLProtocol.install { request in
            recorder.record(request.url!)
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
        MockURLProtocol.install { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 500), errorBody)
            }
            return (Self.response(for: request.url!, statusCode: 200), Data("[]".utf8))
        }

        let raw = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)

        #expect(raw.configJSON == errorBody)
    }

    @Test("a thrown transport error on the config.json fetch propagates from fetchRawMetadata")
    func thrownTransportErrorOnConfigFetchPropagates() async throws {
        MockURLProtocol.install { request in
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
        MockURLProtocol.install { request in
            if request.url!.path.hasSuffix("config.json") {
                return (Self.response(for: request.url!, statusCode: 200), Data("{}".utf8))
            }
            throw URLError(.notConnectedToInternet)
        }

        await #expect(throws: URLError.self) {
            _ = try await Self.makeSource().fetchRawMetadata(repo: "org/model", revision: nil)
        }
    }

    /// Builds a canned `HTTPURLResponse` for a status code, defaulting the
    /// headers/protocol fields the tests don't care about.
    private static func response(for url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }
}

/// A thread-safe recorder of the request URLs ``MockURLProtocol`` intercepts, so
/// a `@Sendable` handler closure can record synchronously from the URL Loading
/// System's own execution context.
private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        recorded.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

/// A `URLProtocol` stub that hands canned responses (or throws) to `URLSession`
/// requests without touching the network. The handler is installed per test via
/// ``install(_:)``; the owning suite runs serialized so this single handler slot
/// never races between concurrently-running tests.
private final class MockURLProtocol: URLProtocol {
    private static let handlerBox = HandlerBox()

    /// Installs the handler the next intercepted request(s) invoke.
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        handlerBox.set(handler)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try Self.handlerBox.get()
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Thread-safe single-slot holder for the current test's request handler,
    /// since `URLSession` instantiates ``MockURLProtocol`` internally and there is
    /// no per-test instance to hang the handler off of.
    private final class HandlerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

        func set(_ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
            lock.lock()
            self.handler = handler
            lock.unlock()
        }

        func get() throws -> (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
            lock.lock()
            defer { lock.unlock() }
            guard let handler else {
                throw URLError(.unknown)
            }
            return handler
        }
    }
}
