/// The prompt of the recap call of a session (D206): the one place of its
/// text, as ``CompactionPrompt`` is for a compaction.
///
/// The prompt gives the facts first, one section for each kind, and the
/// instructions last. A section with no facts is left out. The recap call
/// runs in a new blank session of the `flash` slot with this prompt alone,
/// so the model reads nothing of the session itself.
enum SessionRecapPrompt {
    /// The first line of the prompt.
    static let heading = "Below are the facts of a work session of a user with an assistant."

    /// The title of the section of the previous recap.
    static let previousRecapTitle = "The previous recap of the session:"

    /// The title of the section of the user prompts.
    static let promptsTitle = "The user prompts since the previous recap, the oldest first:"

    /// The title of the section of the tool calls.
    static let toolCallsTitle = "The tool calls of the assistant since the previous recap:"

    /// The title of the section of the last message.
    static let lastMessageTitle = "The last message of the assistant:"

    /// The instructions, after the facts.
    static let instructions = """
        Write the recap of this session: one sentence of at most 200 characters.
        Tell what the session did in the past tense, and where it stands now in the present tense.
        Write in the language of the user prompts.
        Give only the sentence: no preamble, no quotes, no list and no line breaks.
        """

    /// The text that starts each item of a list section.
    private static let itemMark = "- "

    /// The text between two sections.
    private static let sectionSeparator = "\n\n"

    /// The text between the title and the lines of a section, and between
    /// two lines.
    private static let lineSeparator = "\n"

    /// The prompt of one recap call.
    ///
    /// - Parameters:
    ///   - previousRecap: The recap that the record holds, or `nil`.
    ///   - prompts: The user prompts, the oldest first.
    ///   - toolCalls: The tool call lines, the oldest first.
    ///   - lastMessage: The last final message, or `nil`.
    /// - Returns: The prompt.
    static func text(previousRecap: String?, prompts: [String], toolCalls: [String], lastMessage: String?) -> String {
        let sections = [
            section(previousRecapTitle, lines: previousRecap.map { [$0] } ?? []),
            section(promptsTitle, lines: prompts.map { itemMark + $0 }),
            section(toolCallsTitle, lines: toolCalls.map { itemMark + $0 }),
            section(lastMessageTitle, lines: lastMessage.map { [$0] } ?? []),
        ].compactMap { $0 }
        return ([heading] + sections + [instructions]).joined(separator: sectionSeparator)
    }

    /// One section of the prompt, or `nil` when it has no lines.
    ///
    /// - Parameters:
    ///   - title: The title of the section.
    ///   - lines: The lines of the section.
    /// - Returns: The section.
    private static func section(_ title: String, lines: [String]) -> String? {
        guard !lines.isEmpty else { return nil }
        return ([title] + lines).joined(separator: lineSeparator)
    }
}
