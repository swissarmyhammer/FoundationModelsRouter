import MLXLMCommon
import os

/// The logger for a rejected tool call that goes back to the model.
private let rejectedToolCallLogger = makeModuleLogger(category: "RejectedToolCall")

/// A rejected tool call that goes back to the model, so the turn can continue.
///
/// When the model writes a tool call that the parser cannot accept,
/// `MLXLanguageModel` throws `RejectedToolCallError`. The parser did not accept
/// the call, so the transcript holds no `.toolCalls` entry for it. A
/// `.toolOutput` entry thus has no call to pair with, even when the rejection
/// knows a call id. The rejection therefore goes back to the model in the
/// prompt of the next attempt: a short tool error that says which call was
/// rejected and why.
///
/// This value copies only the safe fields of `RejectedToolCall`: the reason,
/// the tool name when the parser found one, and the safe `detail` summary. It
/// never copies `RejectedToolCall.rawTextPreview`, which can hold sensitive
/// argument values. The prompt and the log line thus never hold the raw text
/// of the rejected call.
struct RejectedToolCallRetry {
    /// The most times one turn runs its attempt again after a rejected tool
    /// call. A model that writes a rejected call on each attempt then ends the
    /// turn with the rejection error.
    static let limit = 2

    /// The reason the parser gave, in its wire spelling (for example
    /// `invalid_arguments`).
    let reason: String

    /// The name of the tool the rejected call named, or `nil` when the parser
    /// did not find one.
    let toolName: String?

    /// The safe summary of the rejection, or `nil` when the parser gave none.
    /// The parser writes it with no raw model output in it.
    let detail: String?

    /// Makes a retry from the error of a failed attempt.
    ///
    /// - Parameter error: The error the failed attempt threw.
    /// - Returns: `nil` when `error` is not a `RejectedToolCallError`.
    init?(error: any Error) {
        guard let rejected = error as? RejectedToolCallError else { return nil }
        let rejection = rejected.rejection
        reason = rejection.reason.rawValue
        toolName = rejection.toolName
        detail = rejection.detail
    }

    /// The text that separates the prompt of the failed attempt from the tool
    /// error.
    private static let noteSeparator = "\n\n"

    /// The tool error that tells the model which call was rejected, why, and
    /// that it must write the call again.
    private var note: String {
        let call = toolName.map { "Your call to the tool \"\($0)\"" } ?? "Your tool call"
        let summary = detail.map { " \($0)" } ?? ""
        return "Tool error: \(call) was rejected (\(reason)), and no tool ran.\(summary) "
            + "Correct the call and write it again."
    }

    /// The prompt of the retry attempt: the prompt of the failed attempt,
    /// then the tool error.
    ///
    /// The retry must send the prompt of the failed attempt again, because
    /// `LanguageModelSession` keeps no entry of an attempt that throws. When
    /// a retry is rejected again, its prompt already holds the earlier tool
    /// error, so the model sees each rejection of the turn.
    ///
    /// - Parameter failedPrompt: The prompt text of the failed attempt.
    /// - Returns: `failedPrompt`, a blank line, and the tool error.
    func prompt(retrying failedPrompt: String) -> String {
        failedPrompt + Self.noteSeparator + note
    }

    /// Records in the log that a rejected tool call goes back to the model.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose turn runs the retry.
    ///   - retriesLeft: How many more retries the turn can run after this one.
    func logRetry(sessionID: ULID, retriesLeft: Int) {
        rejectedToolCallLogger.warning(
            "session \(sessionID.description, privacy: .public): a rejected tool call (\(reason, privacy: .public), tool \(toolName ?? "unknown", privacy: .private)) goes back to the model; \(retriesLeft, privacy: .public) retries left"
        )
    }
}
