import FoundationModels

/// A `Tool` that observes the session's turn boundary — the point after the
/// outbox drains and before the model call of the turn.
///
/// A host finds turn-boundary tools with `tool as? any TurnBoundaryTool`. The
/// protocol declares no associated types, so that cast succeeds on an `any
/// Tool` existential.
///
/// The hook carries no arguments and no return value: it is a clock tick a
/// tool uses to apply a change it prepared at the side (for example, swapping
/// in a rendered surface it rebuilt out of band), not an event route.
public protocol TurnBoundaryTool: Tool {
    /// The session calls this one time at each turn boundary, after it drains
    /// the outbox and before the model call of the turn.
    func turnWillBegin() async
}
