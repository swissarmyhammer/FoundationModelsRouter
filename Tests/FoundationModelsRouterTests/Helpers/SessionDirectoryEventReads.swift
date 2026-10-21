import FoundationModelsExtras

extension AsyncStream.Iterator where Element == SessionDirectoryEvent {
    /// Reads the next `count` events of the stream. A stream that ends first
    /// gives fewer.
    ///
    /// - Parameter count: How many events to read.
    /// - Returns: The events, in stream order.
    mutating func next(_ count: Int) async -> [SessionDirectoryEvent] {
        var events: [SessionDirectoryEvent] = []
        while events.count < count, let event = await next() {
            events.append(event)
        }
        return events
    }
}
