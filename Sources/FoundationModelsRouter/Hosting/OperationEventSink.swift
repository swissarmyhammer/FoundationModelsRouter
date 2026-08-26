/// A destination `OperationEvent`s are posted to.
///
/// A session host implements this once — its own outbox, log, or UI update
/// channel — and the session-side per-call binding layers (`RunToCompletionTool`
/// or `BackgroundTool` for String-output tools, `ContextBindingTool` for non-String-output
/// ones) post every event a tool
/// emits through the ambient `ToolContext` to it; tools never wire a sink
/// themselves. This package makes no assumption about routing,
/// buffering, or ordering beyond "eventually observed by the host".
public protocol OperationEventSink: Sendable {
    /// Receives one posted event.
    ///
    /// - Parameter event: The event to receive.
    func post(event: OperationEvent) async

    /// Receives one posted ``ToolInvocationRecord`` — the binding layers post
    /// an open record immediately before each wrapped call and a close record
    /// when it returns (also on throw).
    ///
    /// Delivery-only, unlike ``post(event:)``'s events: a record is never staged
    /// for a future turn and never recorded to the transcript — the post-turn
    /// diff stays the recording authority. ``SessionOutbox`` forwards it to
    /// the session actor for live ``SessionEvent/toolInvocation(_:)``
    /// delivery; a sink with no live consumer keeps the default, which
    /// ignores the record.
    ///
    /// - Parameter record: The record to receive.
    func post(invocation record: ToolInvocationRecord) async
}

extension OperationEventSink {
    /// Ignores the record — the default, so a conformer that only consumes
    /// ``OperationEvent``s keeps compiling and keeps its behavior unchanged.
    ///
    /// - Parameter record: The record to ignore.
    public func post(invocation record: ToolInvocationRecord) async {}
}
