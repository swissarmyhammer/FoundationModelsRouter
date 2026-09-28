/// The compaction settings of one session, in one value.
///
/// ``SessionConfiguration/compaction`` holds this value. The flat parameters
/// `budget:`, `compactionPrompt:` and `toolOutputProtection:` of
/// ``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:agentSpawn:discoveryPriming:toolOutputProtection:repetitionDetection:)``
/// are the short form: each call makes one value of this type.
///
/// The sidecar records ``budget`` and ``prompt`` in its flat `budget` and
/// `compactionPrompt` keys, as it did before this type existed. It does not
/// record ``toolOutputProtection``, because that is a closure.
public struct CompactionSettings: Sendable {
    /// The auto-compaction opt-in, or `nil` for manual compaction only.
    public var budget: TokenBudget?

    /// The prompt that automatic compactions send to the summarizer, when
    /// ``budget`` is set.
    public var prompt: CompactionPrompt

    /// The host rule whose protected tool outputs every compaction on the
    /// session keeps word for word, or `nil` to protect nothing.
    ///
    /// A closure, so the sidecar does not record it. A host gives it again
    /// when it restores the session, as it gives the tools. A fork inherits
    /// it. See ``ToolOutputProtection``.
    public var toolOutputProtection: ToolOutputProtection?

    /// Creates the compaction settings of a session. Each parameter defaults
    /// to the matching default of `RoutedModel.makeSession`.
    ///
    /// - Parameters:
    ///   - budget: The auto-compaction opt-in, or `nil` for manual compaction only.
    ///   - prompt: The prompt that automatic compactions send to the summarizer.
    ///   - toolOutputProtection: The host rule whose protected tool outputs
    ///     every compaction keeps word for word, or `nil` to protect nothing.
    public init(
        budget: TokenBudget? = nil,
        prompt: CompactionPrompt = .default,
        toolOutputProtection: ToolOutputProtection? = nil
    ) {
        self.budget = budget
        self.prompt = prompt
        self.toolOutputProtection = toolOutputProtection
    }
}
