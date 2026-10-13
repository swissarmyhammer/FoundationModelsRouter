/// Why a session refused a `Transcript.Prompt`
/// (``RoutedSession/send(_:)-(Transcript.Prompt)``).
public enum PromptRefusal: Error, Sendable, Equatable {
    /// The prompt has no `.text` segment. A session sends only the text of a
    /// prompt to the model, so a prompt with no text has nothing to send.
    case noTextSegment
}
