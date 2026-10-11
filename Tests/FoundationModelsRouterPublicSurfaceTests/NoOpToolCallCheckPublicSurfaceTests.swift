import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds ``NoOpToolCallCheck`` and ``SessionConfiguration/isNoOpToolCall`` to
/// the access level a consumer outside this package needs (task ^rw72f4j). A
/// host gives the check when it vends a session, and reads the named default.
///
/// The import is plain, with no `@testable`, so a member that loses `public`
/// stops this file from compiling before a single test runs.
@Suite("NoOpToolCallCheck and the no-op check of a configuration over a plain import")
struct NoOpToolCallCheckPublicSurfaceTests {
    /// The name of the tool that the host check of this suite marks.
    private static let noOpToolName = "runCode"

    /// The arguments of every call that this suite checks.
    private static let arguments = GeneratedContent(properties: ["code": "return null"])

    @Test("a consumer sets the check on a configuration, and the configuration gives it back")
    func aConsumerSetsTheCheck() {
        let check: NoOpToolCallCheck = { toolName, _ in toolName == Self.noOpToolName }
        let configuration = SessionConfiguration(isNoOpToolCall: check)

        #expect(configuration.isNoOpToolCall(Self.noOpToolName, Self.arguments))
        #expect(!configuration.isNoOpToolCall("search", Self.arguments))
    }

    @Test("the named default marks no call, and a configuration with no check carries it")
    func theDefaultMarksNoCall() {
        #expect(!SessionConfiguration.defaultIsNoOpToolCall(Self.noOpToolName, Self.arguments))
        #expect(!SessionConfiguration().isNoOpToolCall(Self.noOpToolName, Self.arguments))
    }
}
