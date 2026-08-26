import FoundationModels

@testable import FoundationModelsRouter

/// Test-only, `Arguments`-erased access to a mount layer's wrapped tool, so
/// ``detachmentWrapped(_:)`` can peel the layer without knowing which
/// `Arguments` specialization a suite's fake tools use.
private protocol DetachmentLayerPeelable {
    /// The tool the mount layer wraps.
    var detachmentWrappedTool: any Tool { get }
}

extension RunToCompletionTool: DetachmentLayerPeelable {
    var detachmentWrappedTool: any Tool { wrapped }
}

extension BackgroundTool: DetachmentLayerPeelable {
    var detachmentWrappedTool: any Tool { wrapped }
}

extension ContextBindingTool: DetachmentLayerPeelable {
    var detachmentWrappedTool: any Tool { wrapped }
}

/// Peels the layer every composition site wraps around a tool —
/// ``RunToCompletionTool`` or ``BackgroundTool`` over a String-output tool,
/// or the binding-only ``ContextBindingTool`` over a non-String-output one —
/// returning the inner tool, or `nil` when `tool` is none of them.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`)
/// so the peeling logic lives in exactly one place.
func detachmentWrapped(_ tool: (any Tool)?) -> (any Tool)? {
    (tool as? any DetachmentLayerPeelable)?.detachmentWrappedTool
}
