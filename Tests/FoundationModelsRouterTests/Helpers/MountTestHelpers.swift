import FoundationModels

@testable import FoundationModelsRouter

/// Test-only, `Arguments`-erased access to a mount layer's wrapped tool, so
/// ``mountWrapped(_:)`` can peel the layer without knowing which
/// `Arguments` specialization a suite's fake tools use.
private protocol MountLayerPeelable {
    /// The tool the mount layer wraps.
    var mountWrappedTool: any Tool { get }
}

extension RunToCompletionRunner: MountLayerPeelable {
    var mountWrappedTool: any Tool { wrapped }
}

extension BackgroundToolRunner: MountLayerPeelable {
    var mountWrappedTool: any Tool { wrapped }
}

extension ContextBindingTool: MountLayerPeelable {
    var mountWrappedTool: any Tool { wrapped }
}

/// Peels the layer every composition site wraps around a tool —
/// ``RunToCompletionRunner`` or ``BackgroundToolRunner`` over a String-output tool,
/// or the binding-only ``ContextBindingTool`` over a non-String-output one —
/// returning the inner tool, or `nil` when `tool` is none of them.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`)
/// so the peeling logic lives in exactly one place.
func mountWrapped(_ tool: (any Tool)?) -> (any Tool)? {
    (tool as? any MountLayerPeelable)?.mountWrappedTool
}
