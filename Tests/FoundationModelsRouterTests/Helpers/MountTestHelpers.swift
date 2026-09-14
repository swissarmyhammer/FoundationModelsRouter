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
/// A ``ToolFailureDelivery`` decorator over that layer is peeled first, so a
/// tool of a session's model-facing list peels to the tool it mounts.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`)
/// so the peeling logic lives in exactly one place.
func mountWrapped(_ tool: (any Tool)?) -> (any Tool)? {
    (failureDeliveryPeeled(tool) as? any MountLayerPeelable)?.mountWrappedTool
}

/// Peels the ``ToolFailureDelivery`` decorator that the session mount puts
/// outermost, and returns the layer beneath it. A tool with no such decorator
/// comes back unchanged, and `nil` stays `nil`.
///
/// The composition-site suites read the mount layers beneath the decorator:
/// the capping layer, a runner, or the binding-only layer.
func failureDeliveryPeeled(_ tool: (any Tool)?) -> (any Tool)? {
    tool.map(ToolFailureDelivery.throwingTool(of:))
}

extension ToolCallResult {
    /// The wrapped tool's own output, or `nil` when the call ended as a
    /// failure.
    var wrappedOutput: Output? {
        guard case .output(let output) = self else { return nil }
        return output
    }

    /// The failure text the model reads, or `nil` when the call returned an
    /// output.
    var failureText: String? {
        guard case .failure(let text) = self else { return nil }
        return text
    }
}
