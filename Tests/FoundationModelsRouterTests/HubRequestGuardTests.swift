import Foundation
import HuggingFace
import Testing

/// Proves that the ``HubRequestGuard`` of the unit test bundle is in place: a
/// default session configuration puts the guard first, and the guard takes a
/// request to the Hub and no other request.
///
/// No test sends a request. An issue that the guard records on a thread of
/// the URL loading system is not in the scope of `withKnownIssue`, thus these
/// tests read the configuration and `canInit(with:)` of the guard.
@Suite("Hub request guard of the unit tests")
struct HubRequestGuardTests {
    /// A path of the Hub API, as a hub client asks for it.
    private static let hubPath = "api/models/router-tests/guarded-model"

    /// A host that is not the Hub.
    private static let otherHost = URL(string: "https://example.com/")

    @Test("a default session configuration puts the guard first")
    func defaultConfigurationPutsTheGuardFirst() throws {
        let first: AnyClass = try #require(URLSessionConfiguration.default.protocolClasses?.first)

        #expect(ObjectIdentifier(first) == ObjectIdentifier(HubRequestGuard.self))
    }

    @Test("the guard takes a request to the Hub")
    func guardTakesAHubRequest() {
        let request = URLRequest(url: HubClient.defaultHost.appending(path: Self.hubPath))

        #expect(HubRequestGuard.canInit(with: request))
    }

    @Test("the guard does not take a request to another host")
    func guardDoesNotTakeAnotherRequest() throws {
        let request = URLRequest(url: try #require(Self.otherHost))

        #expect(!HubRequestGuard.canInit(with: request))
    }
}
