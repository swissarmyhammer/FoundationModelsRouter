/// The instructions given to the model-assisted ``Summarization`` compaction
/// stage (compaction_plan.md §1.3 stage 3, §1.4, §2): what to preserve, how
/// to structure the continuation summary, and a `name` so recorded folds can
/// be attributed to the prompt that produced them.
///
/// Passed to ``Compactor/compact(_:prompt:budget:summarizer:summarization:pendingRuns:)``; consumers
/// pass their own value to specialize summarization for their domain (e.g. a
/// coding agent adding "always list test commands") while keeping
/// ``default`` as the research-backed starting point.
public struct CompactionPrompt: Sendable, Equatable, Codable {
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
    /// steps / constraints / critical context). Eight numbered sections:
    /// Intent, Stated facts, Constraints & decisions, Completed, In progress,
    /// Files & code, Errors & fixes, Next steps — no padding, no
    /// meta-commentary.
    ///
    /// `Stated facts` exists because the other seven have nowhere to put a
    /// bare fact the user simply told the assistant — a location, a code, a
    /// name, a number is not a constraint, a decision, a file, an error, or a
    /// next step. Without a slot of its own, such content is elided into a
    /// meta-sentence in `Intent` ("the user gave the location of the spare
    /// toner"), which records THAT a fact was stated and discards WHAT it was:
    /// a fold that silently drops a fact while leaving a plausible-looking
    /// summary behind. `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift`'s
    /// `defaultPromptKeepsBareStatedFacts` pins the section so it cannot be
    /// removed silently.
    ///
    /// Named `"router-default-v2"` rather than plain `"default"` so a fold's
    /// recorded ``CompactionSegment/Content/promptName`` unambiguously
    /// identifies this exact wording, distinct from the `"router-default-v1"`
    /// revision it supersedes and from any future one.
    public static let `default` = CompactionPrompt(
        name: "router-default-v2",
        text: """
            You are compacting an agent conversation into a continuation summary. The
            summary will REPLACE the older conversation: whoever continues has no other
            memory of it, so anything you omit is lost. Be precise and dense. State only
            facts from the conversation — never invent, never infer beyond it.

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
