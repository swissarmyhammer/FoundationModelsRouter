@testable import FoundationModelsRouter

extension AsyncStream where Element == SessionOutput {
    /// The events of this stream of session output, without their origins, in
    /// the same order.
    ///
    /// A test that reads only the events of ``RoutedSession/streamSessionEvents()``
    /// reads them through this stream. The new stream buffers without bound,
    /// as the session feed does. It ends when this stream ends. When the test
    /// stops to read it, the task that copies the events stops too.
    var events: AsyncStream<SessionEvent> {
        let (events, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        let copy = Task {
            for await output in self {
                continuation.yield(output.event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in copy.cancel() }
        return events
    }
}
