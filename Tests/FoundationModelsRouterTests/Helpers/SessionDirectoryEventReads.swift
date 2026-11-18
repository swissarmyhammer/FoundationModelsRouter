import FoundationModelsExtras

extension AsyncStream.Iterator where Element == SessionDirectoryEvent {
    /// Reads the next `count` events of the stream. A stream that ends first
    /// gives fewer.
    ///
    /// - Parameter count: How many events to read.
    /// - Returns: The events, in stream order.
    mutating func next(count: Int) async -> [SessionDirectoryEvent] {
        var events: [SessionDirectoryEvent] = []
        while events.count < count, let event = await next() {
            events.append(event)
        }
        return events
    }

    /// Reads events until the `messageDelivered` event of the message `id`.
    /// Open the stream before the delivery, or the event is not in it.
    ///
    /// - Parameter id: The id of the message.
    /// - Returns: The delivered message, or `nil` when the stream ended first.
    mutating func nextDelivery(of id: MailID) async -> SessionMessage? {
        while let event = await next() {
            if case .messageDelivered(let message) = event, message.id == id { return message }
        }
        return nil
    }

    /// Reads events up to and including `marker`, and leaves out each
    /// `stateChanged`: the turn that a start mails sends them at times the
    /// test does not control. A stream that ends first gives what it had.
    ///
    /// - Parameter marker: An event no session sends, which the test
    ///   emitted after the call under test returned.
    /// - Returns: The events before `marker`, then `marker`, in stream order,
    ///   with no `stateChanged`.
    mutating func next(through marker: SessionDirectoryEvent) async -> [SessionDirectoryEvent] {
        var events: [SessionDirectoryEvent] = []
        while let event = await next() {
            if case .stateChanged = event { continue }
            events.append(event)
            if event == marker { break }
        }
        return events
    }
}
