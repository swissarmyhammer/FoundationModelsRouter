import FoundationModels

@testable import FoundationModelsRouter

/// Test-only, `Arguments`-erased access to an ``ElevatingTool``'s wrapped
/// tool, so ``elevationWrapped(_:)`` can peel the elevation layer without
/// knowing which `Arguments` specialization a suite's fake tools use.
private protocol ElevationLayerPeelable {
    /// The tool the elevation layer wraps.
    var elevationWrappedTool: any Tool { get }
}

extension ElevatingTool: ElevationLayerPeelable {
    var elevationWrappedTool: any Tool { wrapped }
}

/// Peels the elevation layer every composition site wraps around a
/// String-output tool, returning the inner (connected) tool — or `nil`
/// when `tool` is not an ``ElevatingTool``.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`)
/// so the peeling logic lives in exactly one place.
func elevationWrapped(_ tool: (any Tool)?) -> (any Tool)? {
    (tool as? any ElevationLayerPeelable)?.elevationWrappedTool
}
