import FoundationModels
import Testing

import FoundationModelsRouter

/// Holds the message API of ``RoutedSession`` to the access level a consumer
/// outside this package needs (task ^cbhpdjy): ``RoutedSession/send(_:)-(Transcript.Prompt)``,
/// ``MessageID``, ``RoutedSession/cancel()`` and
/// ``RoutedSession/cancel(message:)``, with their result types.
///
/// The import is plain, with no `@testable`, so a member or a case that loses
/// `public` stops this file from compiling before a single test runs.
@Suite("RoutedSession message API over a plain import")
struct MessageQueuePublicSurfaceTests {
    /// What a consumer's queue view keeps for one message it sent.
    struct SentMessage {
        /// The id ``RoutedSession/send(_:)-(String)`` gave the message.
        let id: MessageID

        /// The text the consumer sent.
        let text: String
    }

    /// Sends `text` to `session`, as a consumer's queue view does, and keeps
    /// the id the session gave it.
    ///
    /// - Parameters:
    ///   - text: The prompt text to send.
    ///   - session: The session to send it to.
    /// - Returns: The sent message.
    static func send(_ text: String, to session: any RoutedSession) async -> SentMessage {
        SentMessage(id: await session.send(text), text: text)
    }

    /// Takes back a sent message, as a consumer's "remove" button does, and
    /// labels the outcome.
    ///
    /// - Parameters:
    ///   - message: The message to cancel.
    ///   - session: The session the message was sent to.
    /// - Returns: The label of the outcome.
    static func takeBack(_ message: SentMessage, from session: any RoutedSession) async -> String {
        label(for: await session.cancel(message: message.id))
    }

    /// Stops a session, as a consumer's "stop" button does, and labels the
    /// outcome.
    ///
    /// - Parameter session: The session to stop.
    /// - Returns: The label of the outcome.
    static func stop(_ session: any RoutedSession) async -> String {
        label(for: await session.cancel())
    }

    /// The label a consumer shows for the outcome of a message cancel.
    ///
    /// - Parameter result: The outcome.
    /// - Returns: The label.
    static func label(for result: MessageCancellationResult) -> String {
        switch result {
        case .withdrawn:
            "removed from the queue"
        case .cancelledInSubmission:
            "stopping"
        case .alreadyAnswered:
            "already answered"
        }
    }

    /// The label a consumer shows for the outcome of a session cancel.
    ///
    /// - Parameter result: The outcome.
    /// - Returns: The label.
    static func label(for result: CancellationResult) -> String {
        switch result {
        case .requested:
            "stopping"
        case .nothingToCancel:
            "idle"
        }
    }

    @Test("a consumer names each outcome of cancel(message:)")
    func aConsumerNamesEachMessageCancellationOutcome() {
        #expect(Self.label(for: MessageCancellationResult.withdrawn) == "removed from the queue")
        #expect(Self.label(for: MessageCancellationResult.cancelledInSubmission) == "stopping")
        #expect(Self.label(for: MessageCancellationResult.alreadyAnswered) == "already answered")
    }

    @Test("a consumer names each outcome of cancel()")
    func aConsumerNamesEachCancellationOutcome() {
        #expect(Self.label(for: CancellationResult.requested) == "stopping")
        #expect(Self.label(for: CancellationResult.nothingToCancel) == "idle")
    }

    @Test(
        "a consumer keys its queue view by MessageID, and drives send, take-back and stop through the public protocol"
    )
    func aConsumerDrivesTheMessageAPIThroughTheProtocol() {
        // The four calls a queue view makes type-check over the plain import.
        let send: (String, any RoutedSession) async -> SentMessage = Self.send(_:to:)
        let takeBack: (SentMessage, any RoutedSession) async -> String = Self.takeBack(_:from:)
        let stop: (any RoutedSession) async -> String = Self.stop(_:)
        let sendPrompt: (any RoutedSession) async -> MessageID = { await $0.send(Transcript.Prompt(segments: [])) }
        withExtendedLifetime((send, takeBack, stop, sendPrompt)) {}

        // A view keeps a message in a dictionary keyed by its id, and shows it.
        let identifier: Any.Type = MessageID.self
        let isAQueueKey = identifier is any QueueKey.Type
        #expect(isAQueueKey)
    }

    /// What a consumer's queue view needs of the id of a message: a key it
    /// can hash, send across tasks, and show.
    typealias QueueKey = Hashable & Sendable & CustomStringConvertible
}
