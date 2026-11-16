import Foundation
import HuggingFace
import ObjectiveC
import Testing

@testable import FoundationModelsExtras

/// Makes each unit test that sends a request to the Hugging Face Hub fail.
///
/// A unit test gives `offline: true` to each hub source, thus it sends no
/// request. A test that forgets it still passes: the Hub answers 401 or 404
/// and the source falls back to the cache. This guard finds that test.
///
/// The Extras hub source sends each request through a
/// `URLSession(configuration: .default)`, and such a session does not read
/// the protocols that `URLProtocol.registerClass(_:)` registers. Thus the
/// guard exchanges the implementation of `URLSessionConfiguration.default`:
/// each default configuration then puts the guard first. The guard also
/// registers itself for `URLSession.shared`, which the Router sizing source
/// uses by default. An ephemeral session, such as the session of
/// `StubURLProtocol`, does not get the guard.
///
/// The guard takes only a request to a Hub host. It records an issue that
/// names the URL and fails the request with
/// `URLError(.notConnectedToInternet)`, thus no request leaves the process.
/// The issue comes from a thread of the URL loading system, thus Swift Testing
/// shows it as an issue of an unknown test, and the run fails.
///
/// Swift Testing has no hook at the start of the process, thus a module
/// initializer of the test bundle arms the guard when the bundle loads,
/// before each test. The guard is in this test target only: the real-model
/// suites of the `IntegrationTests` package and
/// `FoundationModelsRouterRealModelSupport` do not get it.
final class HubRequestGuard: URLProtocol {
    /// The hosts of the Hub: the host that the Extras hub source sends to, and
    /// the default host of the Hugging Face client.
    private static let hubHosts = Set([HubSource.host(), HubClient.defaultHost].compactMap { $0.host() })

    /// Arms the guard one time, when the test bundle loads. The section holds
    /// the initializers that the dynamic loader calls when it loads the
    /// bundle.
    @section("__DATA,__mod_init_func") @used
    static let moduleInitializer: @convention(c) () -> Void = { HubRequestGuard.arm() }

    /// Puts the guard in each default session configuration and in
    /// `URLSession.shared`, one time for the process.
    private static let armed: Void = {
        let configuration: AnyClass = URLSessionConfiguration.self
        guard
            let original = class_getClassMethod(
                configuration, #selector(getter: URLSessionConfiguration.default)),
            let guarded = class_getClassMethod(
                configuration, #selector(URLSessionConfiguration.hubGuardedDefault))
        else {
            preconditionFailure("URLSessionConfiguration has no default configuration to guard.")
        }
        method_exchangeImplementations(original, guarded)
        URLProtocol.registerClass(HubRequestGuard.self)
    }()

    /// Arms the guard. A second call does nothing.
    static func arm() {
        _ = armed
    }

    /// Whether `host` is a Hub host or a subdomain of one.
    ///
    /// - Parameter host: The host of a request.
    /// - Returns: `true` for a host of the Hub.
    private static func isHubHost(_ host: String) -> Bool {
        hubHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Takes each request to a Hub host.
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host().map(isHubHost) ?? false
    }

    /// Gives the request back unchanged.
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// Records an issue that names the URL, and fails the request.
    override func startLoading() {
        let url = request.url?.absoluteString ?? "no URL"
        Issue.record(
            "A unit test sent a request to the Hugging Face Hub: \(url). Give offline: true to the hub source.")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    /// Does nothing: `startLoading()` fails the request at once, thus nothing
    /// is left to stop.
    override func stopLoading() {}
}

extension URLSessionConfiguration {
    /// The default configuration with ``HubRequestGuard`` as its first
    /// protocol. After the exchange of the implementations, this selector
    /// runs the original `default`, and `default` runs this method.
    ///
    /// - Returns: A new default configuration that the guard watches.
    @objc dynamic fileprivate class func hubGuardedDefault() -> URLSessionConfiguration {
        let configuration = hubGuardedDefault()
        configuration.protocolClasses = [HubRequestGuard.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}
