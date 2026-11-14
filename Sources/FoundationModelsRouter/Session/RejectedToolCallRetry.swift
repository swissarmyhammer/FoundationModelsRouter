import FoundationModels
import Logging
import MLXLMCommon

/// A rejected tool call that goes back to the model, so the answer can continue.
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
    /// The reason the parser gave, in its wire spelling (for example
    /// `invalid_arguments`).
    let reason: String

    /// The name of the tool the rejected call named, or `nil` when the parser
    /// did not find one.
    let toolName: String?

    /// The safe summary of the rejection, or `nil` when the parser gave none.
    /// The parser writes it with no raw model output in it.
    let detail: String?

    /// The names of the tools that the model can call, when the rejected call
    /// named a tool that the session does not declare, else empty.
    let declaredToolNames: [String]

    /// Makes a retry from the error of a failed attempt.
    ///
    /// - Parameters:
    ///   - error: The error the failed attempt threw.
    ///   - declaredToolNames: The names of the tools that the model can call.
    ///     The tool error names them only for a call to an undeclared tool.
    /// - Returns: `nil` when `error` is not a `RejectedToolCallError`.
    init?(error: any Error, declaredToolNames: [String]) {
        guard let rejected = error as? RejectedToolCallError else { return nil }
        let rejection = rejected.rejection
        reason = rejection.reason.rawValue
        toolName = rejection.toolName
        detail = rejection.detail
        self.declaredToolNames = rejection.reason == .undeclaredTool ? declaredToolNames : []
    }

    /// The text that separates the prompt of the failed attempt from the tool
    /// error.
    private static let noteSeparator = "\n\n"

    /// The tool error that tells the model which call was rejected, why, and
    /// that it must write the call again.
    ///
    /// A call to an undeclared tool gets the names of the declared tools in
    /// place of the parser's detail, because that detail does not say what
    /// to call instead (task ^eesq24a).
    private var note: String {
        let call = toolName.map { "Your call to the tool \"\($0)\"" } ?? "Your tool call"
        guard !declaredToolNames.isEmpty else {
            let summary = detail.map { " \($0)" } ?? ""
            return "Tool error: \(call) was rejected (\(reason)), and no tool ran.\(summary) "
                + "Correct the call and write it again."
        }
        let missing = toolName.map { "There is no tool \"\($0)\"." } ?? "That tool does not exist."
        let declared = declaredToolNames.map { "\"\($0)\"" }.joined(separator: ", ")
        return "Tool error: \(call) was rejected (\(reason)), and no tool ran. \(missing) "
            + "The tools you can call are \(declared). Do the work with one of them."
    }

    /// The prompt of the retry attempt: the prompt of the failed attempt,
    /// then the tool error.
    ///
    /// The retry must send the prompt of the failed attempt again, because
    /// `LanguageModelSession` keeps no entry of an attempt that throws. When
    /// a retry is rejected again, its prompt already holds the earlier tool
    /// error, so the model sees each rejection of the answer.
    ///
    /// - Parameter failedPrompt: The text that the session added after the
    ///   mail of the failed attempt, or `nil` when the prompt of the failed
    ///   attempt was only the render of its mail. The retry renders that mail
    ///   again before this text.
    /// - Returns: `failedPrompt`, a blank line, and the tool error; or only
    ///   the tool error when `failedPrompt` is `nil`.
    func prompt(retrying failedPrompt: String?) -> String {
        guard let failedPrompt else { return note }
        return failedPrompt + Self.noteSeparator + note
    }

    /// The constant message of the log record of ``logRetry(sessionID:ordinal:to:)``.
    static let retryLogMessage = "a rejected tool call goes back to the model"

    /// Records in the log that a rejected tool call goes back to the model.
    ///
    /// - Parameters:
    ///   - sessionID: The session whose answer runs the retry.
    ///   - ordinal: Which retry of the answer this is: 1 for the first retry.
    ///   - logger: The logger of the session.
    func logRetry(sessionID: ULID, ordinal: Int, to logger: Logger) {
        var metadata: Logger.Metadata = [
            RouterTelemetry.LogMetadataKey.sessionId: "\(sessionID.description)",
            RouterTelemetry.LogMetadataKey.rejectionReason: "\(reason)",
            RouterTelemetry.LogMetadataKey.retryOrdinal: "\(ordinal)",
        ]
        // A tool name is safe: it names the tool, and it holds no argument.
        if let toolName {
            metadata[RouterTelemetry.LogMetadataKey.toolName] = "\(toolName)"
        }
        logger.warning("\(Self.retryLogMessage)", metadata: metadata)
    }
}

/// ``RoutedSessionActor``'s resume of an attempt whose model call a rejected
/// tool call ended after a tool result.
///
/// `LanguageModelSession` keeps no entry of a call that throws. A rejection
/// in the first pass loses nothing: the retry sends the prompt again
/// (``RejectedToolCallRetry/prompt(retrying:)``). A rejection in a later pass
/// would lose each tool call and output of the earlier passes, and the model
/// would start the task again with only its prompt. Recursive Flint did this
/// on django-13447 (2026-11-14): a coder loaded its skills, ran a tool, then
/// called an undeclared tool, and the retry started over and ended the
/// answer with no change. So the attempt is rebuilt from the transcript read
/// at its newest tool result (``ToolResultWatch/boundaryEntries``), and the
/// answer goes on with only the tool error as its prompt.
extension RoutedSessionActor {
    /// The names of the tools that the model can call: the tool definitions
    /// of the leading instructions entry of ``backend``, which the model
    /// reads, or the names of ``tools`` when that entry declares none.
    var declaredToolNames: [String] {
        if case .instructions(let instructions) = backend.transcriptEntries().first,
            !instructions.toolDefinitions.isEmpty
        {
            return instructions.toolDefinitions.map(\.name)
        }
        return tools.map(\.name)
    }

    /// Reads the backend transcript at a tool result of the session's own
    /// open model call, where the SDK waits in the tool call and writes no
    /// transcript. A tool body that outlived its model call reads nothing.
    func noteToolResultBoundary() {
        guard SessionCallMark.current?.isOpenCall(of: id) == true else { return }
        toolResultWatch.boundaryEntries = backend.transcriptEntries()
    }

    /// Records the attempt that a rejected tool call ended, with each tool
    /// call and output up to its newest tool result, and goes on with the
    /// tool error.
    ///
    /// The rebuild (``recordAttemptStoppedAtRound(liveEntries:results:attempt:keeping:)``)
    /// pairs the results of the newest round to its calls. The rejected call
    /// has no entry, because the parser did not accept it.
    ///
    /// - Parameters:
    ///   - retry: The rejection.
    ///   - liveEntries: The backend transcript read at the newest tool result.
    ///   - attempt: The attempt that the rejection ended.
    ///   - body: The model work to run.
    /// - Returns: The response text of the next attempt.
    /// - Throws: What the next attempt throws.
    func continueAfterRejectedCall(
        _ retry: RejectedToolCallRetry,
        liveEntries: [Transcript.Entry],
        attempt: StoppedAttempt,
        body: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let ordinal = attempt.rejectedCallRetries + 1
        retry.logRetry(sessionID: id, ordinal: ordinal, to: sessionLogger(.rejectedToolCall))
        await recordAttemptStoppedAtRound(liveEntries: liveEntries, results: noOpToolCallRound.results, attempt: attempt)
        return try await runSubmission(
            grammar: attempt.grammar, deliveredMail: [], ownPrompt: retry.prompt(retrying: nil),
            responseTokenCeiling: attempt.responseTokenCeiling, onEvent: attempt.onEvent,
            allowOverflowRetry: attempt.allowOverflowRetry, rejectedCallRetries: ordinal, isContinuation: true, body)
    }
}
