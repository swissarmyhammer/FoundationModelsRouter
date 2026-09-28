import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouter
import Operations
import Testing

/// Pins that each public name that `FoundationModelsRouter` and the Extras
/// `Operations` module both have is one type with no ambiguity (task
/// ^cs9w81q).
///
/// FoundationModelsAgents imports the router and `Operations` in one file, and
/// the `@Operation` macro writes `ToolMount` into the code it makes. This file
/// imports the router, `Operations` and the Extras core module with a plain
/// `import`, and uses each shared name without a module prefix. The file
/// compiles only when no name is ambiguous. `AgentOperationFixtures` covers
/// the same names in a file that imports the router and `Operations` only.
@Suite("One type for each name that the router and Operations both have")
struct OperationsNameClashTests {
    /// The tool name of the local tool of this file.
    private static let toolName = "operations-name-clash-tool"

    /// The tool description of the local tool of this file.
    private static let toolDescription = "A tool that only the Operations name-clash tests use."

    /// The output of each call of the local tool of this file.
    private static let toolOutput = "done"

    /// The timeout of the mount that the tests make, in seconds.
    private static let mountTimeoutSeconds = 30.0

    /// The unqualified `ToolMount` and `ToolMountError` compile, and each is
    /// the Extras type.
    @Test("a file that imports the router and Operations uses the unqualified mount names")
    func unqualifiedMountNamesCompile() {
        let mount = ToolMount(mode: .background, timeout: Self.mountTimeoutSeconds)
        #expect(mount.mode == .background)
        #expect(mount.timeout == Self.mountTimeoutSeconds)
        let error: ToolMountError = .timedOut(tool: Self.toolName, timeoutSeconds: Self.mountTimeoutSeconds)
        #expect(error == ToolMountError.timedOut(tool: Self.toolName, timeoutSeconds: Self.mountTimeoutSeconds))
        #expect(ToolMount.self == FoundationModelsExtras.ToolMount.self)
        #expect(ToolMountError.self == FoundationModelsExtras.ToolMountError.self)
    }

    /// The concrete operation event names are the same types in the router,
    /// `Operations` and the Extras core module.
    @Test("the concrete shared names of the router and Operations are one type each")
    func concreteSharedNamesAreOneType() {
        #expect(FoundationModelsRouter.ToolMount.self == Operations.ToolMount.self)
        #expect(FoundationModelsRouter.OperationEvent.self == Operations.OperationEvent.self)
        #expect(FoundationModelsRouter.OperationEventKind.self == Operations.OperationEventKind.self)
        #expect(FoundationModelsRouter.OperationOutcome.self == Operations.OperationOutcome.self)
        #expect(OperationEvent.self == FoundationModelsExtras.OperationEvent.self)
        #expect(OperationEventKind.self == FoundationModelsExtras.OperationEventKind.self)
        #expect(OperationOutcome.self == FoundationModelsExtras.OperationOutcome.self)
    }

    /// `OperationEventSink` is one protocol: a local sink that conforms
    /// through the unqualified name casts to each qualified name.
    @Test("OperationEventSink of the router and Operations is one protocol")
    func operationEventSinkIsOneProtocol() {
        let sink: any Sendable = OperationsClashEventSink()
        #expect(sink is any FoundationModelsRouter.OperationEventSink)
        #expect(sink is any Operations.OperationEventSink)
        #expect(
            (any FoundationModelsRouter.OperationEventSink).self == (any Operations.OperationEventSink).self)
    }

    /// `ForkableTool` is one protocol: a local tool that conforms through the
    /// unqualified name casts to each qualified name.
    @Test("ForkableTool of the router and Operations is one protocol")
    func forkableToolIsOneProtocol() {
        let tool: any Tool = OperationsClashForkableTool()
        #expect((tool as? any FoundationModelsRouter.ForkableTool)?.forked().name == Self.toolName)
        #expect((tool as? any Operations.ForkableTool)?.forked().name == Self.toolName)
        #expect((any FoundationModelsRouter.ForkableTool).self == (any Operations.ForkableTool).self)
    }

    // MARK: - Local conformers

    /// A tool that conforms to the unqualified `ForkableTool`.
    private struct OperationsClashForkableTool: ForkableTool {
        let name = OperationsNameClashTests.toolName
        let description = OperationsNameClashTests.toolDescription

        /// Returns the fixed output.
        func call(arguments: GeneratedContent) async throws -> String {
            OperationsNameClashTests.toolOutput
        }
    }

    /// A sink that conforms to the unqualified `OperationEventSink` and drops
    /// each event.
    private struct OperationsClashEventSink: OperationEventSink {
        /// Drops the event.
        func post(event: OperationEvent) async {}
    }
}
