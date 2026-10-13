import Foundation
import FoundationModels
import FoundationModelsExtras

extension Transcript.Prompt {
    /// A prompt of one `.text` segment: the form a plain-text message takes.
    ///
    /// - Parameter text: The text of the prompt.
    /// - Returns: The prompt.
    static func plainText(_ text: String) -> Transcript.Prompt {
        Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: text))])
    }
}

/// The options that one submission fixes at its start, which decide which
/// mail can share it (`mailbox.md`, section 4).
///
/// The SDK fixes the options of a call at its start. A stream goes alone,
/// because the fragments of the call belong to one mail. Two reply mails
/// share a submission when they name the same token ceiling. The grammar of
/// the session is the same for every reply.
struct SubmissionOptions: Sendable, Equatable {
    /// The options of a submission that only run mail started: a reply, with
    /// no ceiling from a caller. The resolved context of the model, bounded
    /// by the pass token limit of the session, is the ceiling.
    static let mailDelivery = SubmissionOptions(isStream: false, requestedMaxTokens: nil)

    /// Whether the submission gives its output as a stream.
    let isStream: Bool

    /// The token ceiling the callers named, or `nil`. The pump gives it to
    /// each submission of the answer, and it is part of the key that groups
    /// the mail of one submission.
    let requestedMaxTokens: Int?

    /// Makes the options.
    ///
    /// - Parameters:
    ///   - isStream: Whether the submission gives its output as a stream.
    ///   - requestedMaxTokens: The token ceiling the callers named, or `nil`.
    init(isStream: Bool, requestedMaxTokens: Int?) {
        self.isStream = isStream
        self.requestedMaxTokens = requestedMaxTokens
    }

    /// The options that the submission of `mail` fixes at its start, or
    /// `nil` for run mail, which has no options of its own.
    ///
    /// A user message gives its own options. A guided session never streams:
    /// a user message in stream mode runs as a reply under the grammar, and
    /// its text is only in the terminal event. An agent message and an
    /// elicitation answer are replies with no ceiling from a caller.
    ///
    /// - Parameters:
    ///   - mail: The mail.
    ///   - isGuided: Whether the session has a grammar.
    init?(for mail: Mail, isGuided: Bool) {
        switch mail.body {
        case .userMessage(_, let options):
            self.init(isStream: options.mode == .stream && !isGuided, requestedMaxTokens: options.maxTokens)
        case .agentMessage, .elicitationAnswer:
            self = .mailDelivery
        case .runEvent:
            return nil
        }
    }

    /// Whether a submission with these options can also carry a mail with
    /// the options `other`.
    ///
    /// - Parameter other: The options of a waiting mail.
    /// - Returns: `true` when neither is a stream and both name the same
    ///   token ceiling.
    func admits(_ other: SubmissionOptions) -> Bool {
        !isStream && other == self
    }
}

extension Mail {
    /// The run event of run mail, or `nil` for user-type mail.
    var runEvent: OperationEvent? {
        guard case .runEvent(let event) = body else { return nil }
        return event
    }

    /// Whether the mail is run mail (``MailBody/runEvent(_:)``). All other
    /// mail is user-type mail: a user message, an agent message or an
    /// elicitation answer. User-type mail always starts an answer, and the
    /// first user-type mail of a batch decides its options.
    var isRunMail: Bool {
        runEvent != nil
    }

    /// The text of user-type mail in the prompt of a submission, or `nil`
    /// for run mail, which goes into the preamble instead.
    ///
    /// - A user message is its prompt.
    /// - An agent message is one line that names the session id of the
    ///   sender, then its content.
    /// - An elicitation answer is one line that names the elicitation id,
    ///   the action and the content.
    var promptText: String? {
        switch body {
        case .userMessage(let prompt, _):
            return prompt
        case .agentMessage(let sender, let content):
            return "[message from session \(sender.ulidString)]\n\(content)"
        case .elicitationAnswer(let elicitationID, let response):
            return
                "[answer to elicitation \(elicitationID.ulidString)] \(response.action.rawValue): \(Self.contentText(of: response))"
        case .runEvent:
            return nil
        }
    }

    /// The content of an elicitation answer as JSON text with sorted keys,
    /// or `none` when the answer has no content.
    ///
    /// - Parameter response: The answer.
    /// - Returns: The text of the content.
    private static func contentText(of response: ElicitationResponse) -> String {
        guard let content = response.content else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // The values are strings, numbers, Booleans and string arrays, so the
        // encoder always succeeds. The text is only for the model to read.
        guard let data = try? encoder.encode(content), let text = String(data: data, encoding: .utf8) else {
            return "unreadable content"
        }
        return text
    }
}

/// What the first submission of one answer carries: the mail that the pump
/// took for it, in queue order.
struct SubmissionBatch: Sendable {
    /// The mail of the batch, in queue order.
    let mail: [Mail]

    /// The user-type mail of the batch, in queue order. None when only run
    /// mail starts the submission.
    var userMail: [Mail] {
        mail.filter { !$0.isRunMail }
    }

    /// The run mail of the batch, in queue order.
    var runMail: [Mail] {
        mail.filter(\.isRunMail)
    }

    /// The ids of the mail of the batch, in queue order.
    var ids: [MailID] {
        mail.map(\.id)
    }
}
