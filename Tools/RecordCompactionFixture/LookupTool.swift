import FoundationModels
import FoundationModelsRouterTestSupport

/// The one tool shape the recorded conversation mounts, twice: `lookup-alpha`
/// and `lookup-beta` are two instances of this struct that differ only in
/// name.
///
/// The tool answers with ``ToolTurnScenario/marker(for:)`` — the
/// `MARKER-7F3A-<step>` shape the rest of the test suite already speaks — so
/// a reader of the recording can tell a delivered tool output from model
/// prose at a glance, and nothing about the marker is restated here.
struct LookupTool: Tool {
    /// The tool's name, as the model calls it: `lookup-alpha` or
    /// `lookup-beta`.
    let name: String

    /// The description both instances share, byte for byte what the
    /// checked-in recording's tool definitions carry.
    let description = "Looks up the record for a step name and returns its identifier."

    /// The tool's one argument: the step name to look up.
    ///
    /// The type name matters: the recorded tool definitions carry the schema
    /// title `StepArguments`, which `@Generable` derives from this name.
    @Generable
    struct StepArguments {
        /// The step name to look up.
        let step: String
    }

    /// Answers with the deterministic marker for `arguments.step`.
    ///
    /// - Parameter arguments: The step name the model asked about.
    /// - Returns: The `MARKER-7F3A-<step>` identifier.
    func call(arguments: StepArguments) async throws -> String {
        ToolTurnScenario.marker(for: arguments.step)
    }
}
