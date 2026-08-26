import FoundationModels

/// A `Tool` that can produce a per-session instance of itself at fork time.
///
/// A host finds forkable tools with `tool as? any ForkableTool`. The protocol declares no associated types, so that cast succeeds on an `any Tool` existential.
/// At fork, the host applies `forked()` first and then wraps the result in the child session's own layers.
public protocol ForkableTool: Tool {
    /// Returns a child session's instance of this tool.
    /// A class-based tool must override this. The default returns `self`, which is correct only for a value-semantics tool.
    /// - Returns: The forked tool instance.
    func forked() -> any Tool
}

extension ForkableTool {
    /// Blanket default: returns `self` unchanged.
    public func forked() -> any Tool { self }
}
