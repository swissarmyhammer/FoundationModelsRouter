import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises ``ToolFailureDelivery`` (task ^dvkxz7n): the decorator that the
/// session mount puts outermost, so a failed call is a tool result that the
/// model reads, and only a cancellation throws.
///
/// The decorator is only on the model-facing mount. A tool that is not in it
/// keeps the throw of its mount layers.
@Suite("ToolFailureDelivery: a failure is the call's output, a cancellation throws")
struct ToolFailureDeliveryTests {
    /// The step every call of this suite names.
    private static let step = "ONE"

    /// The arguments every call of this suite sends.
    private static let arguments = AmbientToolArguments(value: step)

    /// The text the model reads for a call of a marker tool that failed on
    /// ``step``.
    private static let failureText = String(describing: ThrowingMarkerTool.CallFailure(step: step))

    /// A tool-output token cap, so the session mount adds its capping layer.
    /// Only its presence matters, not its size.
    private static let cappedToolOutputLimit = 256

    // MARK: - The rule

    @Test("a body that returns keeps its output")
    func returnedOutputIsKept() async throws {
        let result = try await ToolCallResult<String> { Self.step }

        #expect(result.wrappedOutput == Self.step)
        #expect(result.failureText == nil)
    }

    @Test("a body that throws gives the description of its error as the failure text")
    func thrownErrorBecomesTheFailureText() async throws {
        let result = try await ToolCallResult<String> {
            throw ThrowingMarkerTool.CallFailure(step: Self.step)
        }

        #expect(result.failureText == Self.failureText)
        #expect(result.wrappedOutput == nil)
    }

    @Test("a body that throws a CancellationError throws it again")
    func cancellationIsThrownAgain() async throws {
        await #expect(throws: CancellationError.self) {
            _ = try await ToolCallResult<String> { throw CancellationError() }
        }
    }

    // MARK: - A String-output tool

    @Test("a String-output tool that throws gives the failure text as its String output")
    func stringOutputToolFailureIsText() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: ThrowingMarkerTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<AmbientToolArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == Self.failureText)
    }

    @Test("a String-output tool that ends as cancelled still throws the cancellation")
    func stringOutputToolCancellationThrows() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: CancellingMarkerTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<AmbientToolArguments>)

        await #expect(throws: CancellationError.self) {
            _ = try await tool.call(arguments: Self.arguments)
        }
    }

    @Test("a String-output tool's output passes through unchanged")
    func stringOutputPassesThrough() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: MarkerEmittingTool())
        let tool = try #require(wrapped as? FailureDeliveringTextTool<AmbientToolArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == ScriptedToolFixture.marker(for: Self.step))
    }

    // MARK: - A tool whose output is not String

    @Test("a non-String-output tool that throws gives the failure text as its result")
    func nonStringOutputToolFailureIsTheResult() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: ThrowingNonStringMarkerTool())
        let tool = try #require(
            wrapped as? FailureDeliveringResultTool<AmbientToolArguments, NonStringToolOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        #expect(result.failureText == Self.failureText)
    }

    @Test("a non-String-output tool's plain prompt output passes through, and stays a prompt")
    func nonStringOutputPassesThrough() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: NonStringMarkerTool())
        let tool = try #require(
            wrapped as? FailureDeliveringResultTool<AmbientToolArguments, NonStringToolOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        #expect(result.wrappedOutput?.text == ScriptedToolFixture.marker(for: Self.step))
        // A plain prompt output stays a prompt: the SDK records it as text.
        #expect(!(result is any ConvertibleToGeneratedContent))
    }

    @Test("a structured output keeps its generated content, so the SDK still records a structure")
    func structuredOutputKeepsItsGeneratedContent() async throws {
        let wrapped = ToolFailureDelivery.makeWrapped(tool: StructuredMarkerTool())
        let tool = try #require(
            wrapped as? FailureDeliveringResultTool<AmbientToolArguments, StructuredMarkerOutput>)

        let result = try await tool.call(arguments: Self.arguments)

        let expected = StructuredMarkerOutput(marker: ScriptedToolFixture.marker(for: Self.step))
        // The assignment compiles only when the conditional conformance holds.
        let convertible: any ConvertibleToGeneratedContent = result
        #expect(convertible.generatedContent == expected.generatedContent)
    }

    // MARK: - The tool beneath

    @Test("throwingTool(of:) gives the tool beneath the decorator, which still throws")
    func throwingToolIsTheToolBeneath() async throws {
        let failing = ThrowingMarkerTool()
        let beneath = ToolFailureDelivery.throwingTool(of: ToolFailureDelivery.makeWrapped(tool: failing))
        let tool = try #require(beneath as? ThrowingMarkerTool)

        #expect(tool === failing)
        await #expect(throws: ThrowingMarkerTool.CallFailure(step: Self.step)) {
            _ = try await tool.call(arguments: Self.arguments)
        }
    }

    @Test("throwingTool(of:) gives a tool with no decorator back unchanged")
    func throwingToolOfAnUndecoratedTool() throws {
        let failing = ThrowingMarkerTool()

        let tool = try #require(ToolFailureDelivery.throwingTool(of: failing) as? ThrowingMarkerTool)

        #expect(tool === failing)
    }

    // MARK: - The session mount

    @Test(
        "the session mount puts the decorator outermost, over the capping layer",
        arguments: [nil, cappedToolOutputLimit])
    func sessionMountPutsTheDecoratorOutermost(tokenLimit: Int?) throws {
        let mounted = ToolMounting.makeSessionMounted(
            tool: ThrowingMarkerTool(), sessionID: .generate(), mailbox: SessionMailbox(),
            sink: DiscardingOperationEventSink(), cappedToTokenLimit: tokenLimit)

        #expect(mounted is FailureDeliveringTextTool<AmbientToolArguments>)
        let beneath = ToolFailureDelivery.throwingTool(of: mounted)
        let expectsCapping = tokenLimit != nil
        #expect((beneath is TokenCappingTool<AmbientToolArguments>) == expectsCapping)
    }

    @Test("a failed call through the whole session mount is a tool result")
    func sessionMountedFailureIsAToolResult() async throws {
        let mounted = ToolMounting.makeSessionMounted(
            tool: ThrowingMarkerTool(), sessionID: .generate(), mailbox: SessionMailbox(),
            sink: DiscardingOperationEventSink(), cappedToTokenLimit: nil)
        let tool = try #require(mounted as? FailureDeliveringTextTool<AmbientToolArguments>)

        let output = try await tool.call(arguments: Self.arguments)

        #expect(output == Self.failureText)
    }
}
