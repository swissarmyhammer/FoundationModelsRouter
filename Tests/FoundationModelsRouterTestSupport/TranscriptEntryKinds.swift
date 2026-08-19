import FoundationModels

/// Names the entry kinds a transcript carries, for the callers that verify a
/// recording keeps the shape of real traffic (task `^4bb3mjv`).
///
/// Two callers share this vocabulary, which is why it lives here rather than
/// inside either of them: `RecordedTranscriptCompactionIntegrationTests`
/// asserts the checked-in recording still carries every kind, and the
/// `RecordCompactionFixture` tool makes the same check over a fresh recording
/// before it hands the recording over.
public enum TranscriptEntryKinds {

    /// The entry kinds a recorded conversation must carry to count as real
    /// traffic: an instructions header, prompts, responses, reasoning, tool
    /// calls and tool outputs.
    ///
    /// A transcript written in Swift forgets these. `^vjf3mdm` and `^wnj3ka3`
    /// were both about a fixture that had quietly stopped being what its own
    /// doc comment claimed, and checking presence against this list is what
    /// makes the same drift loud for a recording.
    public static let realTrafficKinds = [
        "instructions", "prompt", "response", "reasoning", "toolCalls", "toolOutput",
    ]

    /// Every `Transcript.Entry` kind `transcript` carries, each named once,
    /// in the order the kinds first appear.
    ///
    /// Read as a list of names rather than as counts, because the check this
    /// serves is about PRESENCE: a recording that lost its tool traffic
    /// entirely is the drift worth catching, and how many tool calls it
    /// happens to hold is a property of one conversation rather than of the
    /// format.
    ///
    /// - Parameter transcript: The reconstructed conversation.
    /// - Returns: The distinct entry-kind names, in first-appearance order.
    public static func names(of transcript: Transcript) -> [String] {
        var kinds: [String] = []
        for entry in transcript {
            let kind: String
            switch entry {
            case .instructions: kind = "instructions"
            case .prompt: kind = "prompt"
            case .response: kind = "response"
            case .toolCalls: kind = "toolCalls"
            case .toolOutput: kind = "toolOutput"
            case .reasoning: kind = "reasoning"
            @unknown default: kind = "unknown"
            }
            if !kinds.contains(kind) {
                kinds.append(kind)
            }
        }
        return kinds
    }
}
