/// The instructions given to the model-assisted ``Summarization`` compaction
/// stage (compaction_plan.md §1.3 stage 3, §1.4, §2): what to preserve, how
/// to structure the continuation summary, and a `name` so recorded folds can
/// be attributed to the prompt that produced them.
///
/// Passed to ``Compactor/compact(_:prompt:budget:summarizer:)``; consumers
/// pass their own value to specialize summarization for their domain (e.g. a
/// coding harness adding "always list test commands") while keeping
/// ``default`` as the research-backed starting point.
public struct CompactionPrompt: Sendable, Equatable {
    /// This prompt's name, recorded verbatim in
    /// ``CompactionSegment/Content/promptName`` — never the prompt's full
    /// text — so evals and browsers can attribute a fold's summary quality to
    /// the exact prompt that produced it (compaction_plan.md §2). A custom
    /// prompt should carry a name distinguishing it from every other prompt
    /// it might be compared against.
    public var name: String

    /// The summarization instructions sent to the summarizer model verbatim,
    /// immediately ahead of the rendered span being condensed.
    public var text: String

    /// Creates a compaction prompt.
    ///
    /// - Parameters:
    ///   - name: This prompt's name, recorded in the fold's
    ///     ``CompactionSegment``.
    ///   - text: The summarization instructions, sent to the summarizer model
    ///     verbatim.
    public init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    /// The router's default compaction prompt (compaction_plan.md §2),
    /// researched against Claude Code's conversation-summarization prompt
    /// (structured numbered sections; exact paths and identifiers;
    /// security-relevant instructions preserved verbatim) and the Claude
    /// platform's own compaction guidance (completed / in-progress / next
    /// steps / constraints / critical context). Seven numbered sections:
    /// Intent, Constraints & decisions, Completed, In progress, Files & code,
    /// Errors & fixes, Next steps — no padding, no meta-commentary.
    ///
    /// Named `"router-default-v1"` rather than plain `"default"` so a fold's
    /// recorded ``CompactionSegment/Content/promptName`` unambiguously
    /// identifies this exact wording, distinct from any future revision an
    /// eval-driven hill-climb might introduce as `"router-default-v2"`, etc.
    public static let `default` = CompactionPrompt(
        name: "router-default-v1",
        text: """
            You are compacting an agent conversation into a continuation summary. The
            summary will REPLACE the older conversation: whoever continues has no other
            memory of it, so anything you omit is lost. Be precise and dense. State only
            facts from the conversation — never invent, never infer beyond it.

            Structure the summary exactly as:

            1. Intent — the user's request(s) and overall goal, in order given.
            2. Constraints & decisions — instructions, preferences, and decisions still
               in force. Preserve safety- or security-relevant instructions VERBATIM
               (files or data to avoid, operations not to perform, secret handling).
            3. Completed — work finished so far, with concrete outcomes.
            4. In progress — what is being worked on right now, and its exact state.
            5. Files & code — every file path touched or discussed, with the symbols,
               commands, and short code fragments that matter. Exact paths and names.
            6. Errors & fixes — problems encountered and how they were (or were not)
               resolved. Keep failed approaches so they are not repeated.
            7. Next steps — the immediate next actions, in order, detailed enough to
               resume without re-deriving them.

            No praise, no padding, no meta-commentary. Omit a section only if truly
            empty.
            """
    )
}
