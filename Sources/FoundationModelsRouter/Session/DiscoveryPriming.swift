import Foundation
import FoundationModels

/// The opt-in that makes a data-facing turn's first tool call deterministic by
/// construction, by running a mounted discovery tool host-side and seeding the
/// call it made into the turn's own transcript before generation starts.
///
/// A model asked a data question can open its turn in three ways that all look
/// different and are all the same event — a first assistant turn containing zero
/// tool calls: it refuses ("I don't have access to real-time data"), it
/// announces what it is about to do and stops, or it answers from its own
/// training. Upfront prose does not eliminate that class; it only shifts its
/// frequency. Seeding does eliminate it, because there is nothing left for the
/// model to decide: the turn it resumes already contains the discovery call, the
/// concrete typed signatures that call returned, and therefore the evidence that
/// it *does* have access. Its first decision becomes what to do with the
/// signatures.
///
/// The seeded call is a **real** call. The designated tool is invoked
/// host-side — through the session's own instanced (mounted, optionally capped)
/// tool, exactly as the model's own call would be — and its actual output is
/// what lands in the seeded `.toolOutput` entry. Nothing is fabricated or
/// templated, which is what lets the seeded entries be recorded, diffed, and
/// restored by the ordinary machinery with no special case: they are genuine
/// calls that genuinely happened.
///
/// Off by default. A host opts one session in when it vends it
/// (``RoutedModel/makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``);
/// a fork inherits its parent's opt-in. With it off, a turn's transcript
/// construction is untouched.
///
/// ```swift
/// let session = profile.standard.makeSession(
///     tools: [FindAPIs()],
///     discoveryPriming: DiscoveryPriming(tool: "findAPIs", queryProperty: "query")
/// )
/// ```
///
/// Nothing about it is specific to any one tool: it names the mounted tool and
/// the single string-valued property of that tool's arguments the turn's prompt
/// is passed as, so any discovery tool of that shape can be primed.
public struct DiscoveryPriming: Sendable, Equatable, Codable {
    /// The mounted tool's `name`, as it appears in the session's tool list.
    ///
    /// A name no mounted tool answers to is a
    /// ``DiscoveryPrimingFailure/toolNotMounted(tool:)`` — reported, never
    /// fatal.
    public let tool: String

    /// The name of the single string-valued property of ``tool``'s arguments
    /// the turn's prompt is passed as.
    ///
    /// The seeded call's arguments are exactly `{"<queryProperty>": "<prompt>"}`,
    /// decoded into the tool's own `Arguments` type before the call runs — so a
    /// property the tool's schema does not accept fails as a
    /// ``DiscoveryPrimingFailure/argumentsRejected(tool:property:underlying:)``
    /// rather than reaching the tool as nonsense.
    public let queryProperty: String

    /// Creates a priming opt-in.
    ///
    /// - Parameters:
    ///   - tool: The mounted tool's `name`.
    ///   - queryProperty: The name of the string-valued arguments property the
    ///     turn's prompt is passed as.
    public init(tool: String, queryProperty: String) {
        self.tool = tool
        self.queryProperty = queryProperty
    }
}

/// A reason one turn's ``DiscoveryPriming`` could not seed.
///
/// Every case is recoverable by the same rule: the turn generates **unseeded**
/// rather than failing. Priming is an improvement to a turn's opening move, not
/// a precondition for having one, so a failure here can never block a turn.
/// Each one is surfaced as ``SessionEvent/discoveryPrimingFailed(_:)`` so it is
/// visible rather than silent: on ``RoutedSession/streamSessionEvents()`` for
/// every turn whichever entry point ran it, and additionally on the turn's own
/// stream when the turn was started through
/// ``RoutedSession/streamEvents(to:maxTokens:)``.
public enum DiscoveryPrimingFailure: Error, Equatable, Sendable {
    /// No mounted tool answers to ``DiscoveryPriming/tool``.
    ///
    /// - Parameter tool: The name that was looked for.
    case toolNotMounted(tool: String)

    /// The named tool's `Output` is not `String`, so its result carries no
    /// recoverable text to seed a `.toolOutput` segment from.
    ///
    /// `FoundationModels.Prompt` — what every other `PromptRepresentable`
    /// ultimately becomes — exposes no generic way to recover its textual
    /// content, the same limitation ``ToolOutputCapping`` documents for
    /// capping.
    ///
    /// - Parameter tool: The named tool.
    case toolOutputNotText(tool: String)

    /// The named tool's own `Arguments` type rejected
    /// `{"<property>": "<prompt>"}` — typically because the tool's schema has
    /// no such property, or requires more than that one.
    ///
    /// - Parameters:
    ///   - tool: The named tool.
    ///   - property: The ``DiscoveryPriming/queryProperty`` that was used.
    ///   - underlying: The decoding failure, as its description.
    case argumentsRejected(tool: String, property: String, underlying: String)

    /// The discovery call itself threw.
    ///
    /// - Parameters:
    ///   - tool: The named tool.
    ///   - underlying: The thrown error, as its description.
    case callFailed(tool: String, underlying: String)
}

/// Builds one turn's pre-discovery seed: runs the designated mounted tool
/// host-side over the turn's prompt and renders the real call it made as the
/// `.prompt` → `.toolCalls` → `.toolOutput` entries a turn resumes from.
///
/// Deliberately has no knowledge of sessions, backends, or recording. It takes a
/// prompt, an opt-in, and a tool list, and returns entries — so the actor that
/// owns the transcript decides what to do with them, and this stays a pure,
/// directly testable transcript-construction step.
enum DiscoveryPrimer {
    /// Runs `priming`'s designated tool over `prompt` and returns the entries
    /// that seed the turn.
    ///
    /// - Parameters:
    ///   - prompt: The turn's own prompt, passed to the tool as its query and
    ///     recorded as the seeded `.prompt` entry.
    ///   - priming: The opt-in naming the tool and its query property.
    ///   - mountedTools: The session's model-facing tool list — the same
    ///     instanced tools the model itself would call, so the seeded call runs
    ///     through the same mounting and capping layers.
    /// - Returns: The seeded `.prompt`, `.toolCalls`, and `.toolOutput` entries,
    ///   in that order.
    /// - Throws: ``DiscoveryPrimingFailure`` when the tool is not mounted,
    ///   cannot accept the arguments, has no text output, or fails.
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
    ///
    /// - Parameters:
    ///   - query: The string value.
    ///   - property: The property name to carry it under.
    /// - Returns: The arguments content.
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
    /// - Parameters:
    ///   - tool: The mounted tool to call.
    ///   - arguments: The arguments content to decode and call with.
    ///   - property: The query property name, reported in
    ///     ``DiscoveryPrimingFailure/argumentsRejected(tool:property:underlying:)``.
    /// - Returns: The tool's own output text.
    /// - Throws: ``DiscoveryPrimingFailure`` when the tool has no text output,
    ///   rejects the arguments, or fails.
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
    ///
    /// - Parameters:
    ///   - prompt: The turn's own prompt.
    ///   - tool: The called tool's name.
    ///   - arguments: The arguments the call was made with.
    ///   - output: The output the call returned.
    /// - Returns: The seeded entries, in transcript order.
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
