import Foundation
import FoundationModels

/// The opt-in that makes a data-facing turn's first tool call deterministic by
/// construction: a mounted discovery tool runs host-side, and the call it made
/// is seeded into the turn's own transcript before generation starts.
///
/// A model asked a data question can open its turn in three ways that look
/// different and are the same event — a first assistant turn with zero tool
/// calls: it refuses, it announces what it is about to do and stops, or it
/// answers from its own training. Upfront prose does not eliminate that class;
/// it only shifts its frequency. Seeding eliminates it, because nothing is left
/// for the model to decide: the turn it resumes already holds the discovery
/// call and the concrete typed signatures that call returned, which is the
/// evidence that it *does* have access.
///
/// The seeded call is a **real** call, made through the session's own instanced
/// (mounted, optionally capped) tool exactly as the model's own call would be,
/// and its actual output lands in the seeded `.toolOutput` entry. Nothing is
/// fabricated or templated, which is what lets the seeded entries be recorded,
/// diffed and restored by the ordinary machinery with no special case.
///
/// Off by default. A host opts one session in when it vends it
/// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``),
/// and a fork inherits its parent's opt-in. With it off, a turn's transcript
/// construction is untouched.
///
/// Nothing is specific to one tool: any discovery tool whose arguments carry a
/// single string-valued query property can be primed.
public struct DiscoveryPriming: Sendable, Equatable, Codable {
    /// The mounted tool's `name`, as it appears in the session's tool list.
    public let tool: String

    /// The name of the single string-valued property of ``tool``'s arguments
    /// the turn's prompt is passed as.
    ///
    /// The seeded call's arguments are exactly `{"<queryProperty>": "<prompt>"}`,
    /// decoded into the tool's own `Arguments` type before the call runs, so a
    /// property the tool's schema does not accept fails as
    /// ``DiscoveryPrimingFailure/argumentsRejected(tool:property:underlying:)``
    /// rather than reaching the tool as nonsense.
    public let queryProperty: String

    /// Creates a priming opt-in.
    public init(tool: String, queryProperty: String) {
        self.tool = tool
        self.queryProperty = queryProperty
    }
}

/// A reason one turn's ``DiscoveryPriming`` could not seed.
///
/// Every case is recoverable by the same rule: the turn generates **unseeded**
/// rather than failing. Priming improves a turn's opening move; it is not a
/// precondition for having one, so a failure here can never block a turn.
/// Each one is surfaced as ``SessionEvent/discoveryPrimingFailed(_:)`` so it is
/// visible rather than silent: on ``RoutedSession/streamSessionEvents()`` for
/// every turn whichever entry point ran it, and additionally on the turn's own
/// stream when the turn was started through
/// ``RoutedSession/streamEvents(to:maxTokens:)``.
public enum DiscoveryPrimingFailure: Error, Equatable, Sendable {
    /// No mounted tool answers to ``DiscoveryPriming/tool``.
    case toolNotMounted(tool: String)

    /// The named tool's `Output` is not `String`, so its result carries no
    /// recoverable text to seed a `.toolOutput` segment from — the same
    /// limitation ``ToolOutputCapping`` documents for capping.
    case toolOutputNotText(tool: String)

    /// The named tool's own `Arguments` type rejected
    /// `{"<property>": "<prompt>"}` — typically because the tool's schema has
    /// no such property, or requires more than that one.
    case argumentsRejected(tool: String, property: String, underlying: String)

    /// The discovery call itself threw.
    case callFailed(tool: String, underlying: String)
}

/// Builds one turn's pre-discovery seed: runs the designated mounted tool
/// host-side over the turn's prompt and renders the real call it made as the
/// `.prompt` → `.toolCalls` → `.toolOutput` entries a turn resumes from.
///
/// Deliberately has no knowledge of sessions, backends or recording, so the
/// actor that owns the transcript decides what to do with the entries and this
/// stays a pure, directly testable transcript-construction step.
enum DiscoveryPrimer {
    /// Runs `priming`'s designated tool over `prompt` and returns the entries
    /// that seed the turn. `prompt` is both the tool's query and the seeded
    /// `.prompt` entry.
    ///
    /// - Parameter mountedTools: The session's model-facing tool list — the
    ///   same instanced tools the model itself would call, so the seeded call
    ///   runs through the same mounting and capping layers.
    static func seededEntries(
        for prompt: String,
        priming: DiscoveryPriming,
        mountedTools: [any Tool]
    ) async throws(DiscoveryPrimingFailure) -> [Transcript.Entry] {
        guard let tool = mountedTools.first(where: { $0.name == priming.tool }) else {
            throw .toolNotMounted(tool: priming.tool)
        }
        let callArguments = arguments(query: prompt, property: priming.queryProperty)
        let output = try await text(
            from: tool, arguments: callArguments, property: priming.queryProperty)
        return entries(prompt: prompt, tool: tool.name, arguments: callArguments, output: output)
    }

    /// The single-property structure `{"<property>": "<query>"}` the seeded call
    /// is made with — and, unchanged, the `arguments` its recorded
    /// `Transcript.ToolCall` carries, so the persisted arguments are the real
    /// call's real arguments.
    private static func arguments(query: String, property: String) -> GeneratedContent {
        GeneratedContent(
            kind: .structure(
                properties: [property: GeneratedContent(kind: .string(query))],
                orderedKeys: [property]
            )
        )
    }

    /// Calls `tool` with `arguments` and returns its text output.
    ///
    /// Opens the `any Tool` existential generically so the tool's own
    /// `Arguments` type is known at the call site — the only way to decode
    /// `arguments` into it and invoke `call(arguments:)` — and requires
    /// `Output == String` by the same runtime existential cast against `Tool`'s
    /// primary associated types that ``ToolOutputCapping/makeWrapped(tool:toTokenLimit:)``
    /// uses.
    ///
    /// - Parameter property: Carried only so that
    ///   ``DiscoveryPrimingFailure/argumentsRejected(tool:property:underlying:)``
    ///   can name it.
    private static func text(
        from tool: any Tool,
        arguments: GeneratedContent,
        property: String
    ) async throws(DiscoveryPrimingFailure) -> String {
        func open<T: Tool>(_ tool: T) async throws(DiscoveryPrimingFailure) -> String {
            guard let textTool = tool as? any Tool<T.Arguments, String> else {
                throw .toolOutputNotText(tool: tool.name)
            }
            let decoded: T.Arguments
            do {
                decoded = try T.Arguments(arguments)
            } catch {
                throw .argumentsRejected(
                    tool: tool.name, property: property, underlying: String(describing: error))
            }
            do {
                return try await textTool.call(arguments: decoded)
            } catch {
                throw .callFailed(tool: tool.name, underlying: String(describing: error))
            }
        }
        return try await open(tool)
    }

    /// Renders one completed discovery call as the turn's seed.
    ///
    /// The `.toolOutput` entry's id **is** the `Transcript.ToolCall`'s id, which
    /// is what correlates the two — the same pairing an SDK-native call has, and
    /// what ``SessionEvent/toolStatus(id:status:summary:output:)`` is derived from.
    private static func entries(
        prompt: String,
        tool: String,
        arguments: GeneratedContent,
        output: String
    ) -> [Transcript.Entry] {
        let callId = ULID.generate().description
        return [
            .prompt(Transcript.Prompt(segments: [.text(Transcript.TextSegment(content: prompt))])),
            .toolCalls(
                Transcript.ToolCalls([
                    Transcript.ToolCall(id: callId, toolName: tool, arguments: arguments)
                ])
            ),
            .toolOutput(
                Transcript.ToolOutput(
                    id: callId,
                    toolName: tool,
                    segments: [.text(Transcript.TextSegment(content: output))]
                )
            ),
        ]
    }
}
