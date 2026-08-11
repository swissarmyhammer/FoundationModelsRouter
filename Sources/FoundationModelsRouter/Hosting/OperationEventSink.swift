/// A destination `OperationEvent`s are posted to.
///
/// A session host implements this once — its own outbox, log, or UI update
/// channel — and the session-side per-call binding layers (`DetachingTool`
/// for String-output tools, `ContextBindingTool` for non-String-output
/// ones) post every event a tool
/// emits through the ambient `ToolContext` to it; tools never wire a sink
/// themselves. This package makes no assumption about routing,
/// buffering, or ordering beyond "eventually observed by the host".
public protocol OperationEventSink: Sendable {
    /// Receives one posted event.
    ///
    /// - Parameter event: The event to receive.
    func post(_ event: OperationEvent) async
}
