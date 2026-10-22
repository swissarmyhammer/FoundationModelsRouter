import Foundation
import Synchronization

/// A `URLProtocol` stub that answers each request of a stub session from a
/// handler a test installs, so a test of an HTTP client makes no network
/// request.
///
/// `URLSession` makes each protocol instance itself, so there is no instance
/// to give a handler to. The stub keeps one handler for each host instead,
/// and a request reaches the handler of the host of its URL. Two suites that
/// use two hosts thus never share a handler, also when the suites run at the
/// same time in two test targets. A suite whose tests share one host runs
/// serialized.
///
/// The unit test target and the public-surface test target each use this
/// stub. SwiftPM cannot share source between two test targets, thus it
/// stands here.
public final class StubURLProtocol: URLProtocol {
    /// Answers one request: the response and the body, or a thrown error
    /// that the session gives to its caller.
    public typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    /// The handler of each host.
    private static let handlers = Mutex<[String: Handler]>([:])

    /// Installs `handler` for each later request to `host`, in place of the
    /// earlier handler of that host.
    ///
    /// - Parameters:
    ///   - host: The host of the URLs that the handler answers.
    ///   - handler: The answer to each request.
    public static func install(forHost host: String, _ handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    /// Makes an ephemeral session whose one protocol is this stub.
    ///
    /// - Returns: A session that sends each request to the installed handler
    ///   of its host.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Takes each request, thus no request of a stub session leaves the
    /// process.
    override public class func canInit(with request: URLRequest) -> Bool { true }

    /// Gives the request back unchanged, so the handler reads each header
    /// that the client set.
    override public class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Answers the request with the handler of its host, or fails it with
    /// `URLError(.unsupportedURL)` when no handler serves that host.
    override public func startLoading() {
        do {
            let (response, data) = try Self.handler(for: request)(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    /// Does nothing: `startLoading()` answers at once, so nothing is left to
    /// stop.
    override public func stopLoading() {}

    /// The installed handler of the host of `request`.
    ///
    /// - Parameter request: The request to answer.
    /// - Returns: The handler of its host.
    /// - Throws: `URLError(.unsupportedURL)` when no handler serves that host.
    private static func handler(for request: URLRequest) throws -> Handler {
        let host = request.url?.host() ?? ""
        guard let handler = handlers.withLock({ $0[host] }) else {
            throw URLError(.unsupportedURL)
        }
        return handler
    }
}

/// Keeps each request that a ``StubURLProtocol`` handler gives it, in the
/// order the handler gives them.
///
/// A handler runs on a thread of the URL loading system, and the test reads
/// the requests after the call returns, thus a mutex guards the list.
public final class RequestRecorder: Sendable {
    /// The requests, in the order of ``record(_:)``.
    private let recorded = Mutex<[URLRequest]>([])

    /// Makes an empty recorder.
    public init() {}

    /// Keeps `request`.
    ///
    /// - Parameter request: A request that a handler received.
    public func record(_ request: URLRequest) {
        recorded.withLock { $0.append(request) }
    }

    /// Each kept request, in the order of ``record(_:)``.
    public var requests: [URLRequest] {
        recorded.withLock { $0 }
    }

    /// The URL of each kept request that has one, in the order of
    /// ``record(_:)``.
    public var urls: [URL] {
        requests.compactMap(\.url)
    }
}
