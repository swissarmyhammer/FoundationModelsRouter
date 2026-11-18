import FoundationModelsExtras

@testable import FoundationModelsRouter

extension RouterSessionDirectory {
    /// Sends `message`, and then reads the directory events until each
    /// message of a `delivered` or a `started` receipt is delivered.
    ///
    /// A send from a session to a durable session writes an inbox file, and
    /// the scan of the inbox puts the mail in the queue of the session and the
    /// message in its ledger after the send returns (``send(_:)``). The
    /// `messageDelivered` event comes when the pump of the target takes the
    /// mail, after the ledger holds the message, so a test that reads the
    /// ledger of the target waits for it, and never for the clock.
    ///
    /// A `queued` receipt gets no wait: its event comes only when the turn of
    /// the target ends, and a test that holds that turn open would wait
    /// forever.
    ///
    /// - Parameter message: The message to send.
    /// - Returns: The receipts of the send.
    /// - Throws: The errors of ``send(_:)``.
    func sendAndAwaitDelivery(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        var feed = events().makeAsyncIterator()
        let receipts = try await send(message)
        var waiting = Set(
            receipts.filter { $0.outcome == .delivered || $0.outcome == .started }.compactMap(\.messageID))
        while !waiting.isEmpty, let event = await feed.next() {
            if case .messageDelivered(let delivered) = event {
                waiting.remove(delivered.id)
            }
        }
        return receipts
    }

    /// Sends one UI message with `text` from the client `clientID` to the
    /// session `id`, and waits until the directory delivered it
    /// (``sendAndAwaitDelivery(_:)``).
    ///
    /// - Parameters:
    ///   - text: The text of the message.
    ///   - clientID: The UI client that sends the message.
    ///   - id: The session id of the target.
    /// - Returns: The receipts of the send.
    /// - Throws: The errors of ``send(_:)``.
    func sendAndAwaitDelivery(
        _ text: String, fromClient clientID: String, to id: ULID
    ) async throws -> [SessionSendReceipt] {
        try await sendAndAwaitDelivery(
            OutgoingSessionMessage(from: .user(clientID: clientID), to: .session(id), text: text))
    }
}
