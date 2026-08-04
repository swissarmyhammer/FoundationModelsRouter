import FoundationModels

/// A `Tool` that can produce a per-session instance of itself, derived at
/// fork time.
///
/// **Usage contract**, mirroring `EventEmittingTool`'s: a host discovers
/// forkable tools in its `[any Tool]` list by conformance cast (`tool as?
/// any ForkableTool`) and derives each child session's tool instance itself
/// at fork time — `ForkableTool` declares no associated types precisely so
/// that cast succeeds against an `any Tool` existential.
///
/// **Composition order.** At fork, a host applies `forked()` first, then
/// wires events with `connecting(_:)` if the forked tool also emits:
/// `((tool as? any ForkableTool)?.forked() ?? tool)`, then
/// `(forked as? any EventEmittingTool)?.connecting(sink) ?? forked`. A tool
/// conforming to neither protocol passes through shared, unchanged.
public protocol ForkableTool: Tool {
    /// Returns a child session's instance of this tool, derived at fork
    /// time.
    ///
    /// The blanket default (below) simply returns `self` — correct for a
    /// value-semantics (struct) tool, where returning `self` already hands
    /// the caller a genuine new, independent instance. A class-based tool
    /// must override this: returning `self` unchanged would hand every fork
    /// the very same shared instance instead of one of its own.
    ///
    /// - Returns: The forked tool instance.
    func forked() -> any Tool
}

extension ForkableTool {
    /// Blanket default: returns `self` unchanged. See `forked()`'s
    /// documentation for the value-semantics assumption this default makes.
    ///
    /// - Returns: `self`.
    public func forked() -> any Tool { self }
}
