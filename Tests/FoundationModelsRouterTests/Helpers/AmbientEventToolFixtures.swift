import FoundationModels

@testable import FoundationModelsRouter

/// The argument schema the ambient-event tool fixtures below take: a single
/// string the tool echoes back and posts as its event's `detail` — the
/// smallest surface the composition-site wiring suites need.
@Generable
struct AmbientToolArguments {
    let value: String
}

/// Posts one `.completed` event carrying `detail` through the ambient
/// ``ToolContext``, or does nothing when no context is bound — the shared
/// call body of both ambient fixtures below. The identity fields passed
/// here are placeholders: ``ToolContext/post(_:)`` re-stamps
/// `tool`/`op`/`correlationID` with the bound run's own values, so only
/// `kind` and `detail` survive to the sink.
///
/// - Parameter detail: The event detail an asserting test matches on.
func postAmbientCompletedEvent(detail: String) async {
    await ToolContext.current?.post(
        OperationEvent(
            tool: "ambient-fixture", op: "run thing", correlationID: "restamped-by-context",
            kind: .completed, detail: detail))
}

/// A reference-typed `FoundationModels.Tool` that posts one `.completed`
/// event through the ambient ``ToolContext`` while executing — the
/// composition sites wire no per-tool sink, so the context the
/// ``ElevatingTool`` layer binds around each call is the only event route.
///
/// Shared by the composition-site wiring suites
/// (`SessionOutboxToolWiringTests`, `SessionTreeRestorationToolWiringTests`,
/// `ToolOutputCappingTests`) so the fixture lives in exactly one place. A
/// class deliberately, so identity assertions (`===`/`!==`) can prove a
/// composition site passes the very same instance through its wrappers.
final class AmbientEventPostingTool: Tool, Sendable {
    let name = "ambient-emitter"
    let description = "test-only tool that posts a completed event through the ambient ToolContext"

    /// The canned string ``call(arguments:)`` returns, or `nil` to echo the
    /// call's own `value` — the capping suite caps a long canned output, the
    /// wiring suites just echo.
    private let output: String?

    /// Creates the fixture, optionally with a canned output.
    ///
    /// - Parameter output: The canned string every call returns, or `nil`
    ///   (the default) to echo the call's own `value`.
    init(output: String? = nil) {
        self.output = output
    }

    func call(arguments: AmbientToolArguments) async throws -> String {
        await postAmbientCompletedEvent(detail: arguments.value)
        return output ?? "handled: \(arguments.value)"
    }
}

/// A non-`String` `PromptRepresentable` tool output — the output type that
/// keeps a tool outside the pending-envelope machinery (there is no `String`
/// wire form for the envelope to replace), so the composition sites wrap its
/// tool in the binding-only ``ContextBindingTool`` instead of
/// ``ElevatingTool``.
struct NonStringToolOutput: PromptRepresentable, Sendable {
    /// The text the output renders as. The ambient fixture below returns the
    /// bound run's `completionToken` here, so a test can match each call's
    /// posted `correlationID` against what that very call returned.
    let text: String

    /// The `PromptRepresentable` requirement: renders ``text`` as a plain
    /// `Prompt`.
    var promptRepresentation: Prompt { Prompt(text) }
}

/// A `Tool` whose `Output` is not `String`: posts one `.completed` event
/// carrying the call's `value` through the ambient ``ToolContext`` (the
/// shared ``postAmbientCompletedEvent(detail:)`` body), then returns the
/// bound run's `completionToken` as its ``NonStringToolOutput/text`` — or
/// `"unbound"` when no context was bound. The non-String counterpart of
/// ``AmbientEventPostingTool``, for the suites proving the binding-only
/// route keeps per-tool identity and per-call correlation.
final class AmbientNonStringOutputTool: Tool, Sendable {
    let name = "ambient-non-string"
    let description =
        "test-only non-String-output tool that posts through the ambient ToolContext"

    func call(arguments: AmbientToolArguments) async throws -> NonStringToolOutput {
        await postAmbientCompletedEvent(detail: arguments.value)
        return NonStringToolOutput(text: ToolContext.current?.completionToken ?? "unbound")
    }
}

/// A `Tool` that both forks and posts through the ambient ``ToolContext``,
/// so the fork suites can prove ``ForkableTool/forked()`` runs before the
/// child's own elevation layer wraps the result. `generation` proves
/// `forked()` is actually invoked (incremented on every fork) rather than
/// the original being shared unchanged.
final class ForkableAmbientTool: Tool, ForkableTool, Sendable {
    let name = "forkable-ambient"
    let description =
        "test-only tool that forks into a new generation and posts through the ambient ToolContext"

    /// How many `forked()` derivations separate this instance from the
    /// original (which starts at `0`).
    let generation: Int

    /// Creates the fixture at a given fork generation.
    ///
    /// - Parameter generation: The instance's fork generation. Defaults to
    ///   `0`, the original.
    init(generation: Int = 0) {
        self.generation = generation
    }

    /// Derives a child session's instance, marked with the next generation.
    ///
    /// - Returns: A fresh instance one generation deeper.
    func forked() -> any Tool {
        ForkableAmbientTool(generation: generation + 1)
    }

    func call(arguments: AmbientToolArguments) async throws -> String {
        await postAmbientCompletedEvent(detail: arguments.value)
        return "handled: \(arguments.value)"
    }
}
