import Logging

/// A write-ahead marker that the recorder lost, named by what it announced.
///
/// The session writes a marker before the work that it announces runs: a
/// ``TranscriptEvent/Kind/toolCallStarted`` marker before a tool body, and a
/// ``TranscriptEvent/Kind/promptStarted`` marker before the model runs. A
/// marker that is not written is not silent. The recorder logs it with the id
/// of the thing it announced, and counts it. This type holds the wording of
/// that log and the choice of the counter, for the one drop policy of the
/// recorder (``JSONLRecorder``).
enum WriteAheadMarker: Equatable {
    /// The marker of the tool call with this id.
    case toolCall(id: String)

    /// The marker of the user messages that these mail ids name, in take
    /// order.
    case prompt(mailIDs: [String])

    /// The separator between two mail ids in the log metadata of a prompt
    /// marker.
    private static let mailIDSeparator = ", "

    /// The words that name the marker in the message of the log of its loss.
    var subject: String {
        switch self {
        case .toolCall:
            return "tool call marker"
        case .prompt:
            return "prompt marker"
        }
    }

    /// The log metadata that names what the marker announced: the id of the
    /// call, or the ids of the mail.
    var metadata: Logger.Metadata {
        switch self {
        case .toolCall(let id):
            return [RouterTelemetry.LogMetadataKey.toolCallId: "\(id)"]
        case .prompt(let mailIDs):
            return [RouterTelemetry.LogMetadataKey.mailId: "\(mailIDs.joined(separator: Self.mailIDSeparator))"]
        }
    }

    /// Counts the loss of this marker, in the counter of its kind.
    func countLoss() {
        switch self {
        case .toolCall:
            RouterMetrics().recordDroppedToolCallMarker()
        case .prompt:
            RouterMetrics().recordDroppedPromptMarker()
        }
    }
}

extension TranscriptEvent {
    /// The write-ahead marker that this event is, or `nil` for each other
    /// event. A ``Kind/toolCallStarted`` marker names the id of its call. A
    /// ``Kind/promptStarted`` marker names the ids of its mail.
    var writeAheadMarker: WriteAheadMarker? {
        switch kind {
        case .toolCallStarted:
            return entry?.toolCalls?.first.map { .toolCall(id: $0.id) }
        case .promptStarted:
            return .prompt(mailIDs: takenMail.map { "\($0.id)" })
        case .session, .instructions, .prompt, .toolCalls, .toolOutput, .response, .reasoning, .embedding, .divergence,
            .generationCall, .repeatedPartRemoval, .watchStop, .mail, .toolCall, .unknown:
            return nil
        }
    }
}
