import FoundationModels

/// One tool result that the model-facing mount gives back to the model.
///
/// The failure-delivery decorators (``FailureDeliveringTextTool`` and
/// ``FailureDeliveringResultTool``) make one value for each call, after the
/// result is ready and before the model reads it.
struct ToolResultAppend: Sendable {
    /// The name of the tool that the model called.
    let toolName: String

    /// The arguments of the call, or `nil` when the arguments type cannot
    /// give its generated content.
    let arguments: GeneratedContent?

    /// The transcript segment that holds the result.
    let segment: Transcript.Segment

    /// The result as text. The session counts its tokens.
    let text: String

    /// Makes the value for a text result.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool that the model called.
    ///   - arguments: The decoded arguments of the call.
    ///   - text: The text that the model reads.
    init(toolName: String, arguments: Any, text: String) {
        self.toolName = toolName
        self.arguments = Self.generatedContent(of: arguments)
        self.segment = .text(Transcript.TextSegment(content: text))
        self.text = text
    }

    /// Makes the value for a result that is not text.
    ///
    /// A result that gives its generated content becomes a structured
    /// segment. Any other result becomes a text segment of its prompt.
    ///
    /// - Parameters:
    ///   - toolName: The name of the tool that the model called.
    ///   - arguments: The decoded arguments of the call.
    ///   - result: The result that the model reads.
    init(toolName: String, arguments: Any, result: some PromptRepresentable) {
        self.toolName = toolName
        self.arguments = Self.generatedContent(of: arguments)
        guard let content = Self.generatedContent(of: result) else {
            let text = String(describing: result.promptRepresentation)
            self.segment = .text(Transcript.TextSegment(content: text))
            self.text = text
            return
        }
        self.segment = .structure(Transcript.StructuredSegment(schemaName: toolName, content: content))
        self.text = content.jsonString
    }

    /// The generated content of `value`, when its type can give it.
    ///
    /// - Parameter value: The arguments or the result of a call.
    /// - Returns: The generated content, or `nil`.
    private static func generatedContent(of value: Any) -> GeneratedContent? {
        (value as? any ConvertibleToGeneratedContent)?.generatedContent
    }
}

/// The tool-result append boundary of one model call of a turn.
///
/// ``RoutedSessionActor/runCancellableModelCall(composedPrompt:_:)`` binds
/// one boundary around each model call. The model-facing tool decorators
/// read ``current`` and give each tool result to it. A tool result is the one
/// place where the context of a turn grows while the model call is in
/// flight, so the session checks the compaction trigger there (see
/// ``RoutedSessionActor/noteToolResult(_:)``).
///
/// A task-local reaches `Tool.call`: the re-entry refusal of
/// ``GenerationPermitLoan`` depends on the same fact.
final class ToolResultAppendBoundary: Sendable {
    /// The boundary of the model call that the current task runs in, or
    /// `nil` outside a model call.
    @TaskLocal static var current: ToolResultAppendBoundary?

    /// The session whose model call binds this boundary.
    private let session: RoutedSessionActor

    /// Makes the boundary of one model call of `session`.
    ///
    /// - Parameter session: The session whose model call binds it.
    init(session: RoutedSessionActor) {
        self.session = session
    }

    /// Gives one tool result to the session.
    ///
    /// - Parameter result: The result that the model reads next.
    func deliver(result: ToolResultAppend) async {
        await session.noteToolResult(result)
    }
}
