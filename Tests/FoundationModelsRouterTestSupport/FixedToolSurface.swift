import FoundationModels

/// A fixed surface of four tools, like the one a consuming agent mounts for
/// the life of one `LanguageModelSession`: the declared tool set never
/// changes from turn to turn, so the `.instructions` entry that carries it
/// must read the same on every turn.
///
/// The argument schemas carry several properties each. `GenerationSchema`
/// encodes its objects from dictionaries, so a schema with several keys is
/// what makes an unstable encoding visible.
public enum FixedToolSurface {
    /// The arguments of the tool that searches the available tools.
    @Generable
    struct SearchToolsArguments {
        @Guide(description: "The search query.")
        var query: String
        @Guide(description: "The most results to return.")
        var limit: Int
    }

    /// The arguments of the tool that runs a code snippet.
    @Generable
    struct RunCodeArguments {
        @Guide(description: "The code to run.")
        var code: String
        @Guide(description: "The language the code is written in.")
        var language: String
        @Guide(description: "The seconds to wait before the run is stopped.")
        var timeoutSeconds: Int
        @Guide(description: "Whether the run's output is captured.")
        var captureOutput: Bool
        @Guide(description: "The directory the code runs in.")
        var workingDirectory: String
    }

    /// The arguments of the tool that waits for a background run.
    @Generable
    struct WaitArguments {
        @Guide(description: "The id of the run to wait for.")
        var runId: String
        @Guide(description: "The seconds to wait at most.")
        var seconds: Int
    }

    /// The arguments of the tool that loads a skill.
    @Generable
    struct SkillsArguments {
        @Guide(description: "The name of the skill.")
        var name: String
        @Guide(description: "The arguments passed to the skill.")
        var arguments: String
    }

    /// The schema of the run-code arguments, the widest schema of the surface,
    /// for a prompt's response format.
    public static var runCodeSchema: GenerationSchema {
        RunCodeArguments.generationSchema
    }

    /// The four tool definitions, in mount order.
    public static var toolDefinitions: [Transcript.ToolDefinition] {
        [
            Transcript.ToolDefinition(
                name: "searchTools", description: "Searches the available tools.",
                parameters: SearchToolsArguments.generationSchema),
            Transcript.ToolDefinition(
                name: "runCode", description: "Runs a code snippet.",
                parameters: runCodeSchema),
            Transcript.ToolDefinition(
                name: "wait", description: "Waits for a background run.",
                parameters: WaitArguments.generationSchema),
            Transcript.ToolDefinition(
                name: "skills", description: "Loads a skill.",
                parameters: SkillsArguments.generationSchema),
        ]
    }

    /// An `.instructions` entry that declares ``toolDefinitions``.
    ///
    /// - Parameters:
    ///   - id: The entry id.
    ///   - text: The instructions text.
    /// - Returns: The entry.
    public static func instructionsEntry(id: String, text: String) -> Transcript.Entry {
        .instructions(
            Transcript.Instructions(
                id: id,
                segments: [.text(Transcript.TextSegment(content: text))],
                toolDefinitions: toolDefinitions
            )
        )
    }
}
