import Foundation

/// A refusal of a submission to a ``GenerationQueue`` that could never run
/// (`generation-queue.md`, section 5.5, rule 2).
///
/// This is not a lock error. It names a wait cycle: the item of a queue is one
/// whole submission to Foundation, and a tool body runs inside its submission.
/// So a tool body that waits in band for a submission on the same queue waits
/// for an item that runs only after the item of the tool body ends. A hang is
/// worse than an error, so the queue refuses such a submission at once.
public enum GenerationQueueError: Error, Equatable, LocalizedError {
    /// A task inside an open submission on the queue of `model` submitted to
    /// that same queue: an in-band tool body asked a session on the same
    /// model for an answer.
    ///
    /// Start the work from a background tool (`ToolMount(mode: .background)`),
    /// and let its result come back as mail, or wait for work on a different
    /// model.
    case waitInsideOpenSubmission(model: ModelRef)

    /// A localized message that describes the error.
    public var errorDescription: String? {
        switch self {
        case .waitInsideOpenSubmission(let model):
            return """
                A tool body inside a submission to \(model.stringValue) waited for another submission to \
                \(model.stringValue). That submission can run only after the submission of the tool body \
                ends, so the wait could never end. Start the work from a background tool, and let its \
                result come back as mail, or wait for work on a different model.
                """
        }
    }
}
