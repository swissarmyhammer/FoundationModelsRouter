import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouter
import Testing

/// Pins that each public name that `FoundationModelsRouter` and
/// `FoundationModelsExtras` both have is one type.
///
/// The router names these types through public typealiases of the Extras
/// types. A file that imports both modules must thus write each name with no
/// ambiguity. This file imports each module with a plain `import`, as an
/// application does, and uses each name without a module prefix. The file
/// compiles only when no name is ambiguous.
///
/// A test of a concrete type compares the two qualified metatypes. A test of a
/// protocol also conforms a local type through the unqualified name and casts
/// it through each qualified name.
@Suite("One type for each name that the router and Extras both have")
struct ExtrasNameClashTests {
    /// The tool name of the local tools of this file.
    private static let toolName = "name-clash-tool"

    /// The tool description of the local tools of this file.
    private static let toolDescription = "A tool that only the name-clash tests use."

    /// The output of each call of the local tools of this file.
    private static let toolOutput = "done"

    // MARK: - Model pool and queue names

    /// The model pool names are the same types in both modules.
    @Test("the model pool names of the router and Extras are one type each")
    func modelPoolNamesAreOneType() {
        #expect(FoundationModelsRouter.ModelRef.self == FoundationModelsExtras.ModelRef.self)
        #expect(FoundationModelsRouter.ModelPool.self == FoundationModelsExtras.ModelPool.self)
        #expect(FoundationModelsRouter.ModelPoolKey.self == FoundationModelsExtras.ModelPoolKey.self)
        #expect(FoundationModelsRouter.ModelRole.self == FoundationModelsExtras.ModelRole.self)
        #expect(
            (any FoundationModelsRouter.PooledModelLoader).self
                == (any FoundationModelsExtras.PooledModelLoader).self)
        #expect(
            (any FoundationModelsRouter.PooledEmbedding).self
                == (any FoundationModelsExtras.PooledEmbedding).self)
    }

    /// The generation queue and message queue names are the same types in
    /// both modules.
    @Test("the queue names of the router and Extras are one type each")
    func queueNamesAreOneType() {
        #expect(FoundationModelsRouter.GenerationQueue.self == FoundationModelsExtras.GenerationQueue.self)
        #expect(
            FoundationModelsRouter.GenerationQueueError.self == FoundationModelsExtras.GenerationQueueError.self)
        #expect(FoundationModelsRouter.MessageID.self == FoundationModelsExtras.MessageID.self)
        #expect(
            FoundationModelsRouter.MessageQueueMutationResult.self
                == FoundationModelsExtras.MessageQueueMutationResult.self)
        #expect(
            FoundationModelsRouter.MessageCancellationResult.self
                == FoundationModelsExtras.MessageCancellationResult.self)
        #expect(FoundationModelsRouter.MessageQueueDepth.self == FoundationModelsExtras.MessageQueueDepth.self)
    }

    /// A file that imports both modules uses the unqualified model pool names
    /// with no ambiguity.
    @Test("a file that imports both modules uses the unqualified pool names")
    func unqualifiedPoolNamesCompile() {
        let model: ModelRef = "mlx-community/name-clash-model"
        let key = ModelPoolKey(ref: model, role: ModelRole.llm)
        #expect(key.ref == model)
        // `MessageID` has no public initializer, so the test names the type.
        let idType: MessageID.Type = MessageID.self
        #expect(idType == FoundationModelsExtras.MessageID.self)
    }

    // MARK: - Tool hosting names

    /// The concrete tool hosting names are the same types in both modules.
    @Test("the concrete tool hosting names of the router and Extras are one type each")
    func concreteHostingNamesAreOneType() {
        #expect(FoundationModelsRouter.ToolContext.self == FoundationModelsExtras.ToolContext.self)
        #expect(FoundationModelsRouter.ToolMount.self == FoundationModelsExtras.ToolMount.self)
        #expect(FoundationModelsRouter.ToolMountError.self == FoundationModelsExtras.ToolMountError.self)
        #expect(FoundationModelsRouter.RunKind.self == FoundationModelsExtras.RunKind.self)
        #expect(FoundationModelsRouter.BackgroundRun.self == FoundationModelsExtras.BackgroundRun.self)
        #expect(FoundationModelsRouter.WaitOutcome.self == FoundationModelsExtras.WaitOutcome.self)
        #expect(FoundationModelsRouter.CancelOutcome.self == FoundationModelsExtras.CancelOutcome.self)
        #expect(
            FoundationModelsRouter.PendingRunEnvelope.self == FoundationModelsExtras.PendingRunEnvelope.self)
        #expect(
            FoundationModelsRouter.ToolCallAttachment.self == FoundationModelsExtras.ToolCallAttachment.self)
        #expect(FoundationModelsRouter.ToolCallReport.self == FoundationModelsExtras.ToolCallReport.self)
        #expect(
            FoundationModelsRouter.ElicitationAnswerDelivery.self
                == FoundationModelsExtras.ElicitationAnswerDelivery.self)
        #expect(
            FoundationModelsRouter.ElicitationCompletionDelivery.self
                == FoundationModelsExtras.ElicitationCompletionDelivery.self)
    }

    /// A file that imports both modules uses the unqualified concrete tool
    /// hosting names with no ambiguity.
    @Test("a file that imports both modules uses the unqualified tool hosting names")
    func unqualifiedHostingNamesCompile() {
        let mount = ToolMount(mode: ToolMount.Mode.background)
        #expect(mount.mode == .background)
        #expect(ToolMount.synchronous.mode == .runToCompletion)
        let kind: RunKind = .swiftTask
        #expect(kind == FoundationModelsExtras.RunKind.swiftTask)
        let attachment = ToolCallAttachment(schemaName: Self.toolName, contentJSON: "{}")
        #expect(attachment.schemaName == Self.toolName)
        #expect(ToolContext.current == nil)
    }

    /// `LostRunError` is one protocol: a local error that conforms through the
    /// unqualified name casts to each qualified name.
    @Test("LostRunError of the router and Extras is one protocol")
    func lostRunErrorIsOneProtocol() {
        let error: any Error = ClashLostRunError()
        #expect(error is any FoundationModelsRouter.LostRunError)
        #expect(error is any FoundationModelsExtras.LostRunError)
        #expect(
            (any FoundationModelsRouter.LostRunError).self == (any FoundationModelsExtras.LostRunError).self)
    }

    /// `BackgroundTool` is one protocol: a local tool that conforms through
    /// the unqualified name casts to each qualified name.
    @Test("BackgroundTool of the router and Extras is one protocol")
    func backgroundToolIsOneProtocol() {
        let tool: any Tool = ClashBackgroundTool()
        #expect((tool as? any FoundationModelsRouter.BackgroundTool)?.mount?.mode == .background)
        #expect((tool as? any FoundationModelsExtras.BackgroundTool)?.mount?.mode == .background)
        #expect(
            (any FoundationModelsRouter.BackgroundTool).self == (any FoundationModelsExtras.BackgroundTool).self)
    }

    /// `SubmissionBoundaryTool` is one protocol: a local tool that conforms
    /// through the unqualified name casts to each qualified name.
    @Test("SubmissionBoundaryTool of the router and Extras is one protocol")
    func submissionBoundaryToolIsOneProtocol() {
        let tool: any Tool = ClashSubmissionBoundaryTool()
        #expect(tool is any FoundationModelsRouter.SubmissionBoundaryTool)
        #expect(tool is any FoundationModelsExtras.SubmissionBoundaryTool)
        #expect(
            (any FoundationModelsRouter.SubmissionBoundaryTool).self
                == (any FoundationModelsExtras.SubmissionBoundaryTool).self)
    }

    // MARK: - Operation event names

    /// The concrete operation event names are the same types in both modules.
    @Test("the concrete operation event names of the router and Extras are one type each")
    func concreteOperationEventNamesAreOneType() {
        #expect(FoundationModelsRouter.OperationEvent.self == FoundationModelsExtras.OperationEvent.self)
        #expect(
            FoundationModelsRouter.OperationEventKind.self == FoundationModelsExtras.OperationEventKind.self)
        #expect(FoundationModelsRouter.OperationOutcome.self == FoundationModelsExtras.OperationOutcome.self)
        #expect(
            FoundationModelsRouter.ToolInvocationRecord.self == FoundationModelsExtras.ToolInvocationRecord.self)
    }

    /// The elicitation names are the same types in both modules.
    @Test("the elicitation names of the router and Extras are one type each")
    func elicitationNamesAreOneType() {
        #expect(FoundationModelsRouter.ElicitationMode.self == FoundationModelsExtras.ElicitationMode.self)
        #expect(FoundationModelsRouter.ElicitationRequest.self == FoundationModelsExtras.ElicitationRequest.self)
        #expect(
            FoundationModelsRouter.ElicitationRequestedSchema.self
                == FoundationModelsExtras.ElicitationRequestedSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationPrimitiveSchema.self
                == FoundationModelsExtras.ElicitationPrimitiveSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationStringFormat.self
                == FoundationModelsExtras.ElicitationStringFormat.self)
        #expect(
            FoundationModelsRouter.ElicitationStringSchema.self
                == FoundationModelsExtras.ElicitationStringSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationNumberSchema.self
                == FoundationModelsExtras.ElicitationNumberSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationBooleanSchema.self
                == FoundationModelsExtras.ElicitationBooleanSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationSingleSelectSchema.self
                == FoundationModelsExtras.ElicitationSingleSelectSchema.self)
        #expect(
            FoundationModelsRouter.ElicitationMultiSelectSchema.self
                == FoundationModelsExtras.ElicitationMultiSelectSchema.self)
        #expect(FoundationModelsRouter.ElicitationValue.self == FoundationModelsExtras.ElicitationValue.self)
        #expect(
            FoundationModelsRouter.ElicitationResponse.self == FoundationModelsExtras.ElicitationResponse.self)
    }

    /// `OperationEventSink` is one protocol: a local sink that conforms
    /// through the unqualified name casts to each qualified name.
    @Test("OperationEventSink of the router and Extras is one protocol")
    func operationEventSinkIsOneProtocol() {
        let sink: any Sendable = ClashEventSink()
        #expect(sink is any FoundationModelsRouter.OperationEventSink)
        #expect(sink is any FoundationModelsExtras.OperationEventSink)
        #expect(
            (any FoundationModelsRouter.OperationEventSink).self
                == (any FoundationModelsExtras.OperationEventSink).self)
    }

    /// `ForkableTool` is one protocol: a local tool that conforms through the
    /// unqualified name casts to each qualified name.
    @Test("ForkableTool of the router and Extras is one protocol")
    func forkableToolIsOneProtocol() {
        let tool: any Tool = ClashForkableTool()
        #expect((tool as? any FoundationModelsRouter.ForkableTool)?.forked().name == Self.toolName)
        #expect((tool as? any FoundationModelsExtras.ForkableTool)?.forked().name == Self.toolName)
        #expect(
            (any FoundationModelsRouter.ForkableTool).self == (any FoundationModelsExtras.ForkableTool).self)
    }

    // MARK: - Local conformers

    /// An error that conforms to the unqualified `LostRunError`.
    private struct ClashLostRunError: LostRunError {}

    /// A tool that conforms to the unqualified `BackgroundTool`, with a
    /// background mount.
    private struct ClashBackgroundTool: Tool, BackgroundTool {
        let name = ExtrasNameClashTests.toolName
        let description = ExtrasNameClashTests.toolDescription
        let mount: ToolMount? = ToolMount(mode: .background)

        /// Returns the fixed output.
        func call(arguments: GeneratedContent) async throws -> String {
            ExtrasNameClashTests.toolOutput
        }
    }

    /// A tool that conforms to the unqualified `SubmissionBoundaryTool`.
    private struct ClashSubmissionBoundaryTool: SubmissionBoundaryTool {
        let name = ExtrasNameClashTests.toolName
        let description = ExtrasNameClashTests.toolDescription

        /// Does nothing at a submission boundary.
        func submissionWillBegin() async {}

        /// Returns the fixed output.
        func call(arguments: GeneratedContent) async throws -> String {
            ExtrasNameClashTests.toolOutput
        }
    }

    /// A tool that conforms to the unqualified `ForkableTool`.
    private struct ClashForkableTool: ForkableTool {
        let name = ExtrasNameClashTests.toolName
        let description = ExtrasNameClashTests.toolDescription

        /// Returns the fixed output.
        func call(arguments: GeneratedContent) async throws -> String {
            ExtrasNameClashTests.toolOutput
        }
    }

    /// A sink that conforms to the unqualified `OperationEventSink` and
    /// drops each event.
    private struct ClashEventSink: OperationEventSink {
        /// Drops the event.
        func post(event: OperationEvent) async {}
    }
}
