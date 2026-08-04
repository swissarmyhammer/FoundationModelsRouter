/// A destination `OperationEvent`s are posted to.
///
/// A session host implements this once — its own outbox, log, or UI update
/// channel — and connects it to every `EventEmittingTool` it discovers in
/// its `[any Tool]` list (see `EventEmittingTool`'s "hosts connect, users
/// don't" contract). This package makes no assumption about routing,
/// buffering, or ordering beyond "eventually observed by the host".
public protocol OperationEventSink: Sendable {
    /// Receives one posted event.
    ///
    /// - Parameter event: The event to receive.
    func post(_ event: OperationEvent) async
}
