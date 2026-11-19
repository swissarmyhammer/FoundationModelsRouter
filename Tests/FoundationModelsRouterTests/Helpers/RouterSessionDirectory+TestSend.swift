import FoundationModelsExtras
import Testing

@testable import FoundationModelsRouter

extension RouterSessionDirectory {
    /// Sends one message with `text` from `sender` to `address`. The
    /// directory suites use this one send.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - address: The address of the target.
    ///   - sender: The session or the user that sends the message.
    ///   - source: The source session of a user message, or `nil`.
    ///   - awaitingDelivery: `true` to wait until the directory delivered
    ///     each message of a `delivered` or a `started` receipt
    ///     (``sendAndAwaitDelivery(_:)``). Use `false` when no delivery
    ///     follows the send, or when the test reads the events itself.
    /// - Returns: The receipts of the send.
    /// - Throws: The errors of ``send(_:)``.
    func send(
        _ text: String, to address: SessionAddress, from sender: SessionMessageSender,
        sourceSession source: ULID? = nil, awaitingDelivery: Bool = false
    ) async throws -> [SessionSendReceipt] {
        let message = OutgoingSessionMessage(from: sender, to: address, text: text, sourceSession: source)
        if awaitingDelivery { return try await sendAndAwaitDelivery(message) }
        return try await send(message)
    }

    /// Sends one message to the session `id` as
    /// ``send(_:to:from:sourceSession:awaitingDelivery:)`` does for the
    /// address `.session(id)`.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - id: The session id of the target.
    ///   - sender: The session or the user that sends the message.
    ///   - source: The source session of a user message, or `nil`.
    ///   - awaitingDelivery: `true` to wait until the directory delivered
    ///     the message.
    /// - Returns: The receipts of the send.
    /// - Throws: The errors of ``send(_:)``.
    func send(
        _ text: String, to id: ULID, from sender: SessionMessageSender, sourceSession source: ULID? = nil,
        awaitingDelivery: Bool = false
    ) async throws -> [SessionSendReceipt] {
        try await send(
            text, to: SessionAddress.session(id), from: sender, sourceSession: source,
            awaitingDelivery: awaitingDelivery)
    }

    /// Sends one message as ``send(_:to:from:sourceSession:awaitingDelivery:)``
    /// does, and gives the id of the message.
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - id: The session id of the target.
    ///   - sender: The session or the user that sends the message.
    ///   - source: The source session of a user message, or `nil`.
    ///   - awaitingDelivery: `true` to wait until the directory delivered
    ///     the message.
    /// - Returns: The id of the message.
    /// - Throws: The errors of ``send(_:)``, or the `#require` failure when
    ///   the first receipt has no message id.
    func sendMessage(
        _ text: String, to id: ULID, from sender: SessionMessageSender, sourceSession source: ULID? = nil,
        awaitingDelivery: Bool = false
    ) async throws -> MailID {
        let receipts = try await send(
            text, to: id, from: sender, sourceSession: source, awaitingDelivery: awaitingDelivery)
        return try #require(receipts.first?.messageID)
    }
}

extension SessionSendReceipt {
    /// The `sent` receipt of a message to the archived session `target`,
    /// with the note "archived" (D204).
    ///
    /// - Parameters:
    ///   - messageID: The id of the message.
    ///   - target: The session id of the archived session.
    /// - Returns: The receipt.
    static func archived(_ messageID: MailID, to target: ULID) -> SessionSendReceipt {
        SessionSendReceipt(
            messageID: messageID, target: target, outcome: .sent, reason: RouterSessionDirectory.archivedNote)
    }
}
