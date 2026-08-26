/// A destination `OperationEvent`s are posted to.
///
/// A session host implements this once. The per-call binding layers post every event a tool emits through the ambient `ToolContext`; tools never wire a sink themselves. The package guarantees only that the host eventually observes each event.
public protocol OperationEventSink: Sendable {
    /// Receives one posted event.
    func post(event: OperationEvent) async

    /// Receives one posted ``ToolInvocationRecord``: an open record before each wrapped call and a close record when it returns, also on throw.
    /// Delivery-only: a record is never staged for a future turn and never recorded to the transcript.
    /// - Parameter record: The record to receive.
    func post(invocation record: ToolInvocationRecord) async
}

extension OperationEventSink {
    /// Blanket default: ignores the record.
    public func post(invocation record: ToolInvocationRecord) async {}
}
