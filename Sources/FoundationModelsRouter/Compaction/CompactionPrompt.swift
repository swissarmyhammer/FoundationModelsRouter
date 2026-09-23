/// The instructions given to the ``Summarization`` compaction call, with a
/// `name` so recorded compactions can be attributed to the prompt that produced
/// them. Consumers pass their own value to specialize summarization.
public struct CompactionPrompt: Sendable, Equatable, Codable {
    /// This prompt's name, recorded in ``CompactionSegment/Content/promptName``.
    /// A custom prompt must carry a name distinct from every other prompt.
    public var name: String

    /// The summarization instructions sent to the summarizer model verbatim,
    /// after the rendered live context and ahead of the stated size.
    public var text: String

    /// Creates a compaction prompt.
    ///
    /// - Parameters:
    ///   - name: This prompt's name, recorded in the compaction's ``CompactionSegment``.
    ///   - text: The summarization instructions, sent to the summarizer model verbatim.
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// The router's default compaction prompt, `"router-default-v6"`: a short
    /// summary of the few points that matter to continue. ``Summarization``
    /// adds the size budget in tokens to each request.
    public static let `default` = CompactionPrompt(
        name: "router-default-v6",
        text: """
            Summarize the conversation above. Whoever continues has no other memory of it.
            Write a short summary of the few points that matter to go on:
            - what the user wants;
            - what is decided, and what must not be done;
            - what is done, and what comes next;
            - any value the next step needs (a name, a path, a number), written exactly.

            Leave out small talk, and finished work that does not matter next. Use plain sentences or short bullets. Do not list facts for their own sake.
            """
    )
}
