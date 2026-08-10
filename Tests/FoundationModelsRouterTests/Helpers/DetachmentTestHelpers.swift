import FoundationModels

@testable import FoundationModelsRouter

/// Test-only, `Arguments`-erased access to a ``DetachingTool``'s wrapped
/// tool, so ``detachmentWrapped(_:)`` can peel the detachment layer without
/// knowing which `Arguments` specialization a suite's fake tools use.
private protocol DetachmentLayerPeelable {
    /// The tool the detachment layer wraps.
    var detachmentWrappedTool: any Tool { get }
}

extension DetachingTool: DetachmentLayerPeelable {
    var detachmentWrappedTool: any Tool { wrapped }
}

extension ContextBindingTool: DetachmentLayerPeelable {
    var detachmentWrappedTool: any Tool { wrapped }
}

/// Peels the layer every composition site wraps around a tool — the
/// ``DetachingTool`` engine over a String-output tool, or the binding-only
/// ``ContextBindingTool`` over a non-String-output one — returning the
/// inner (connected) tool, or `nil` when `tool` is neither wrapper.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`)
/// so the peeling logic lives in exactly one place.
func detachmentWrapped(_ tool: (any Tool)?) -> (any Tool)? {
    (tool as? any DetachmentLayerPeelable)?.detachmentWrappedTool
}
