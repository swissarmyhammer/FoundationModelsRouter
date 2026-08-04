import FoundationModels

/// A `Tool` that can produce a per-session copy of itself, wired to post
/// `OperationEvent`s to a given `OperationEventSink`.
///
/// **Usage contract (pinned): `connecting` is host-internal machinery, never
/// an end-user call.** A host receives its tools as an ordinary `[any Tool]`
/// list (e.g. a session's `tools:` parameter), discovers emitters by
/// conformance cast (`tool as? any EventEmittingTool`), and wires each one to
/// its own sink itself during setup — implementing this protocol IS the
/// subscription; nobody "remembers" to connect it separately.
/// `EventEmittingTool` declares no associated types precisely so that cast
/// succeeds against an `any Tool` existential.
///
/// **Pure, not mutating.** `connecting(_:)` returns a new tool instance
/// wired to `sink`; it never mutates the receiver. The returned tool shares
/// the receiver's underlying reference-typed state — only the event route
/// differs — so two sessions can each hold their own `connecting(_:)` copy
/// of the same tool, receiving their own events independently, without
/// stealing delivery from one another.
public protocol EventEmittingTool {
    /// Returns a copy of this tool wired to post every event it emits from
    /// then on to `sink`, replacing whatever route (if any) the receiver
    /// had.
    ///
    /// - Parameter sink: The sink the returned tool's events are posted to.
    /// - Returns: A new tool instance sharing the receiver's underlying
    ///   state, routed to `sink`.
    func connecting(_ sink: any OperationEventSink) -> any Tool
}
