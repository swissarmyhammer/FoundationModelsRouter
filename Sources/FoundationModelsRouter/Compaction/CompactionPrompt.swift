/// The instructions given to the ``Summarization`` compaction stage, with a
/// `name` so recorded folds can be attributed to the prompt that produced
/// them. Consumers pass their own value to specialize summarization.
public struct CompactionPrompt: Sendable, Equatable, Codable {
    /// This prompt's name, recorded in ``CompactionSegment/Content/promptName``.
    /// A custom prompt must carry a name distinct from every other prompt.
    public var name: String

    /// The summarization instructions sent to the summarizer model verbatim,
    /// immediately ahead of the rendered span being condensed.
    public var text: String

    /// Creates a compaction prompt.
    ///
    /// - Parameters:
    ///   - name: This prompt's name, recorded in the fold's ``CompactionSegment``.
    ///   - text: The summarization instructions, sent to the summarizer model verbatim.
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// The router's default compaction prompt, `"router-default-v3"`: eight
    /// numbered sections, verbatim values, and a size budget that
    /// ``Summarization`` states per request.
    public static let `default` = CompactionPrompt(
        name: "router-default-v3",
        text: """
            You are compacting an agent conversation into a continuation summary. The
            summary will REPLACE the older conversation: whoever continues has no other
            memory of it, so anything you omit is lost. Be precise and dense. State only
            facts from the conversation — never invent, never infer beyond it.

            Copy every name, identifier, code, number, path, date and value EXACTLY as it
            appears in the conversation — character for character, never paraphrased,
            never abbreviated, never re-derived. "The staging database port is 6432" is
            a kept fact; "the user stated the staging database port" is that fact lost.

            Each request states a size budget for the whole summary, as a word count.
            Aim near it without counting words: keep every section terse, and drop
            polish rather than stated facts. Text far past the budget is trimmed away
            and lost.

            Structure the summary exactly as:

            1. Intent — the user's request(s) and overall goal, in order given.
            2. Stated facts — every concrete fact stated in the conversation, each with
               its value written out: names, identifiers, codes, numbers, locations,
               paths, dates, settings, preferences.
               Record WHAT was stated, never merely THAT something was stated — write
               "the spare toner is in the third-floor supply closet", never "the user
               gave the location of the spare toner".
            3. Constraints & decisions — instructions, preferences, and decisions still
               in force. Preserve safety- or security-relevant instructions VERBATIM
               (files or data to avoid, operations not to perform, secret handling).
            4. Completed — work finished so far, with concrete outcomes.
            5. In progress — what is being worked on right now, and its exact state.
            6. Files & code — every file path touched or discussed, with the symbols,
               commands, and short code fragments that matter. Exact paths and names.
            7. Errors & fixes — problems encountered and how they were (or were not)
               resolved. Keep failed approaches so they are not repeated.
            8. Next steps — the immediate next actions, in order, detailed enough to
               resume without re-deriving them.

            No praise, no padding, no meta-commentary. Omit a section only if truly
            empty. Never replace a stated value with a description of it.
            """
    )
}
