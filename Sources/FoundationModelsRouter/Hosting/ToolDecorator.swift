import FoundationModels

/// A `Tool` that wraps one other tool and stands in its place on a session's
/// mounted tool list.
///
/// Router mounts no bare tool. ``ToolMounting`` composes each registered tool
/// under a ``RunToCompletionRunner`` or a ``BackgroundToolRunner``, under a
/// ``ContextBindingTool`` when the output is not `String`, and under a
/// ``TokenCappingTool`` when a tool-output token cap is configured, and under a
/// ``FailureDeliveringTextTool`` or ``FailureDeliveringResultTool`` on the
/// session's model-facing list. A host that
/// looks for an opt-in protocol on a mounted tool therefore meets a decorator,
/// never the tool the caller registered.
///
/// Naming the tool underneath lets one shared rule walk the chain down to that
/// original — see ``SubmissionBoundaryTool``'s default `submissionWillBegin()`.
protocol ToolDecorator {
    /// The wrapped tool's type. Each decorator fixes it for itself, since the
    /// output type it accepts differs: `any Tool<Arguments, String>` for the
    /// runners and the capping decorator, `any Tool<Arguments, Output>` for the
    /// binding-only decorator.
    associatedtype Wrapped

    /// The tool this decorator stands in front of. It is itself a decorator at
    /// every link but the last, so a rule that walks the chain takes one link
    /// at a time.
    var wrapped: Wrapped { get }
}

extension SubmissionBoundaryTool where Self: ToolDecorator {
    /// Passes the submission boundary to the next link of the decorator chain
    /// when that link conforms, and does nothing when it does not.
    ///
    /// Every decorator shares this one body, so the chain cannot forward the
    /// boundary at one link and drop it at another.
    func submissionWillBegin() async {
        await (wrapped as? any SubmissionBoundaryTool)?.submissionWillBegin()
    }
}
