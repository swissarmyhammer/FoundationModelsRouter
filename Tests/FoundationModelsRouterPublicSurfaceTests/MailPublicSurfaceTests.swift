import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the mail API of ``RoutedSession`` to the access level a consumer
/// outside this package needs (task ^cbhpdjy, `mailbox.md`, section 5):
/// ``RoutedSession/mail(_:)``, ``RoutedSession/send(_:)-(Transcript.Prompt)``,
/// ``MailID``, the signals ``RoutedSession/cancel(_:)``,
/// ``RoutedSession/cancelAll()`` and ``RoutedSession/replace(_:with:)``, which
/// each return a ``SignalID``, the waits ``RoutedSession/awaitTerminal(of:)-(MailID)``,
/// ``RoutedSession/awaitAnswer(of:)`` and
/// ``RoutedSession/awaitTerminal(of:)-(SignalID)``, the refusal types, and
/// the error of a wait that found no record of its id
/// (``TerminalLookupError``).
///
/// The import is plain, with no `@testable`, so a member or a case that loses
/// `public` stops this file from compiling before a single test runs.
@Suite("RoutedSession mail API over a plain import")
struct MailPublicSurfaceTests {
    /// What a consumer's queue view keeps for one message it sent.
    struct SentMessage {
        /// The id ``RoutedSession/send(_:)-(String)`` gave the message.
        let id: MailID
    }

    /// Sends `text` to `session`, as a consumer's queue view does, and keeps
    /// the id the session gave it.
    ///
    /// - Parameters:
    ///   - text: The prompt text to send.
    ///   - session: The session to send it to.
    /// - Returns: The sent message.
    /// - Throws: The refusal of the session.
    static func send(_ text: String, to session: any RoutedSession) throws -> SentMessage {
        SentMessage(id: try session.send(text))
    }

    /// Mails one user message to `session`, as a consumer that reads the
    /// output of its own mail does, and keeps the subscription.
    ///
    /// - Parameters:
    ///   - text: The prompt text to send.
    ///   - session: The session to mail.
    /// - Returns: The output of the mail.
    /// - Throws: The refusal of the session.
    static func mail(_ text: String, to session: any RoutedSession) throws -> MailSubscription<SessionOutput> {
        try session.mail(
            Mail(sender: .user, body: .userMessage(prompt: text, options: UserMessageOptions(mode: .stream))))
    }

    /// Takes back a sent message while it waits, as a consumer's "remove"
    /// button does, and waits for the end of the signal.
    ///
    /// - Parameters:
    ///   - message: The message to cancel.
    ///   - session: The session the message was sent to.
    /// - Returns: The terminal event of the signal.
    /// - Throws: `CancellationError`, or the refusal of a closed session.
    static func takeBack(_ message: SentMessage, from session: any RoutedSession) async throws -> SessionEvent {
        try await session.awaitTerminal(of: session.cancel(message.id))
    }

    /// Changes the text of a sent message while it waits, as a consumer's
    /// "edit" button does, and gives the id of the signal.
    ///
    /// - Parameters:
    ///   - message: The message to change.
    ///   - text: The new prompt text.
    ///   - session: The session the message was sent to.
    /// - Returns: The id of the signal.
    static func edit(_ message: SentMessage, to text: String, in session: any RoutedSession) -> SignalID {
        session.replace(message.id, with: MailBody.userMessage(prompt: text, options: UserMessageOptions()))
    }

    /// Stops all work of a session, as a consumer's "stop" button does, and
    /// gives the id of the signal at once.
    ///
    /// - Parameter session: The session to stop.
    /// - Returns: The id of the signal.
    static func stop(_ session: any RoutedSession) -> SignalID {
        session.cancelAll()
    }

    /// Waits for the end of a sent message, as a consumer's progress view
    /// does.
    ///
    /// - Parameters:
    ///   - message: The message to wait for.
    ///   - session: The session the message was sent to.
    /// - Returns: The terminal event of the message.
    /// - Throws: `CancellationError`, or the refusal of a closed session.
    static func end(of message: SentMessage, in session: any RoutedSession) async throws -> SessionEvent {
        try await session.awaitTerminal(of: message.id)
    }

    /// Waits for the answer of a sent message, as a consumer that shows the
    /// reply, or the typed error of a failed answer, does.
    ///
    /// - Parameters:
    ///   - message: The message to wait for.
    ///   - session: The session the message was sent to.
    /// - Returns: The answer that delivered the message.
    /// - Throws: The error of a failed answer, `CancellationError`, or the
    ///   refusal of a closed session.
    static func answer(of message: SentMessage, in session: any RoutedSession) async throws -> SessionAnswer {
        try await session.awaitAnswer(of: message.id)
    }

    /// The label a consumer shows for a refused mail.
    ///
    /// - Parameter refusal: The refusal.
    /// - Returns: The label.
    static func label(for refusal: MailRefusal) -> String {
        switch refusal {
        case .duplicateID:
            "already sent"
        case .closed:
            "session closed"
        }
    }

    /// The label a consumer shows for a refused prompt.
    ///
    /// - Parameter refusal: The refusal.
    /// - Returns: The label.
    static func label(for refusal: PromptRefusal) -> String {
        switch refusal {
        case .noTextSegment:
            "no text"
        }
    }

    /// The label a consumer shows for a wait that found no record of its id.
    ///
    /// - Parameter error: The error of the wait.
    /// - Returns: The label.
    static func label(for error: TerminalLookupError) -> String {
        switch error {
        case .unknownMail:
            "message not known"
        case .unknownSignal:
            "signal not known"
        }
    }

    @Test("a consumer names each refusal of a mail and of a prompt, and each wait that found no record of its id")
    func aConsumerNamesEachRefusal() {
        #expect(Self.label(for: MailRefusal.duplicateID(MailID())) == "already sent")
        #expect(Self.label(for: MailRefusal.closed) == "session closed")
        #expect(Self.label(for: PromptRefusal.noTextSegment) == "no text")
        #expect(Self.label(for: TerminalLookupError.unknownMail(MailID())) == "message not known")
        #expect(Self.label(for: TerminalLookupError.unknownSignal(SignalID())) == "signal not known")
    }

    @Test(
        "a consumer keys its queue view by MailID, and drives mail, signals and waits through the public protocol"
    )
    func aConsumerDrivesTheMailAPIThroughTheProtocol() {
        // The calls a queue view makes type-check over the plain import.
        let send: (String, any RoutedSession) throws -> SentMessage = Self.send(_:to:)
        let mail: (String, any RoutedSession) throws -> MailSubscription<SessionOutput> = Self.mail(_:to:)
        let takeBack: (SentMessage, any RoutedSession) async throws -> SessionEvent = Self.takeBack(_:from:)
        let edit: (SentMessage, String, any RoutedSession) -> SignalID = Self.edit(_:to:in:)
        let stop: (any RoutedSession) -> SignalID = Self.stop(_:)
        let endOfSignal: (SignalID, any RoutedSession) async throws -> SessionEvent = { try await $1.awaitTerminal(of: $0) }
        let end: (SentMessage, any RoutedSession) async throws -> SessionEvent = Self.end(of:in:)
        let answer: (SentMessage, any RoutedSession) async throws -> SessionAnswer = Self.answer(of:in:)
        let sendPrompt: (any RoutedSession) throws -> MailID = { try $0.send(Transcript.Prompt(segments: [])) }
        withExtendedLifetime((send, mail, takeBack, edit, stop, endOfSignal, end, answer, sendPrompt)) {}

        // A view keeps a message in a dictionary keyed by its id, and shows it.
        let identifier: Any.Type = MailID.self
        let isAQueueKey = identifier is any QueueKey.Type
        #expect(isAQueueKey)
    }

    /// What a consumer's queue view needs of the id of a message: a key it
    /// can hash, send across tasks, and show.
    typealias QueueKey = Hashable & Sendable & CustomStringConvertible
}
