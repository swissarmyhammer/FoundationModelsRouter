import FoundationModels

/// The generated content of the arguments of one tool call.
///
/// The arguments of a tool are `Generable` or `GeneratedContent` in the usual
/// case, and each one gives its generated content. The checks of
/// ``SessionCheckedTool``, the identity of a call (``ToolCallIdentity``) and
/// the tool hooks (``ToolCallHooks``) all read the arguments through this one
/// conversion, so they see the same content.
enum ToolArgumentsContent {
    /// The generated content of `arguments`.
    ///
    /// - Parameter arguments: The arguments of a tool call.
    /// - Returns: The generated content, or `nil` when the arguments do not
    ///   give their generated content.
    static func of(_ arguments: some Any) -> GeneratedContent? {
        (arguments as? any ConvertibleToGeneratedContent)?.generatedContent
    }
}
