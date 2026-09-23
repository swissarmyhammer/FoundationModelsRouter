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

    /// The router's default compaction prompt, `"router-default-v7"`: a line
    /// of the values to keep, then a short summary of the few points that
    /// matter to continue. ``Summarization`` adds the size budget in tokens to
    /// each request.
    ///
    /// The value line comes first. Under `"router-default-v6"`, which asked
    /// for the values as the last of the points and said "Do not list facts
    /// for their own sake", Qwen2.5-3B wrote a summary without the vault code
    /// the user asked it to keep, so the recall after the compaction failed.
    /// A value line at the end was also lost when the summary ran long.
    public static let `default` = CompactionPrompt(
        name: "router-default-v7",
        text: """
            Summarize the conversation above. Whoever continues has no other memory of it.
            Start with a line "Values:" that gives each code, name, path and number the user asked to keep or the next step needs, copied exactly.
            Then write a short summary of the few points that matter to go on:
            - what the user wants;
            - what is decided, and what must not be done;
            - what is done, and what comes next.

            Leave out small talk, and finished work that does not matter next. Use plain sentences or short bullets.
            """
    )
}
