import FoundationModelsExtras

@testable import FoundationModelsRouter

extension RouterSessionDirectory {
    /// Sends `message`, and then reads the directory events until each
    /// message of the receipts that a session received is delivered.
    ///
    /// A send to a durable session writes an inbox file, and the scan of the
    /// inbox puts the mail in the queue of the session and the message in its
    /// ledger after the send returns (``send(_:)``). The `messageDelivered`
    /// event marks that point, so a test that reads the ledger or the queue
    /// of the target waits for it, and never for the clock.
    ///
    /// - Parameter message: The message to send.
    /// - Returns: The receipts of the send.
    /// - Throws: The errors of ``send(_:)``.
    func sendAndAwaitDelivery(_ message: OutgoingSessionMessage) async throws -> [SessionSendReceipt] {
        var feed = events().makeAsyncIterator()
        let receipts = try await send(message)
        var waiting = Set(
            receipts.filter { $0.outcome == .delivered || $0.outcome == .queued }.compactMap(\.messageID))
        while !waiting.isEmpty, let event = await feed.next() {
            if case .messageDelivered(let delivered) = event {
                waiting.remove(delivered.id)
            }
        }
        return receipts
    }
}
