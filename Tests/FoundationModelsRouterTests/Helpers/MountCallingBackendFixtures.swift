import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// One tool call that the first submission of a ``MountCallingBackend``
/// makes: the name of a composed tool and the JSON of its arguments.
struct ScriptedMountCall: Sendable {
    /// The name of the composed tool to call.
    let toolName: String

    /// The arguments of the call, as a JSON object.
    let argumentsJSON: String
}

/// The error a ``MountCallingBackend`` throws when its script names a tool
/// that the session did not compose.
struct UnknownScriptedTool: Error {
    /// The name the script used.
    let toolName: String
}

/// A backend whose first submission makes each ``ScriptedMountCall`` through
/// the composed tool list of the session, in order, as a model would, and
/// answers with the output of the last call. Each later submission answers
/// ``answerPrefix`` plus its prompt, so a test reads which mail reached the
/// model.
///
/// The composed tools are the model-facing tools of the session, so each
/// call goes through the Extras mount layer, which asks the tool for the
/// mount of that call.
///
/// Every mutable field is behind one `Mutex`: the pump of the session runs a
/// delivery submission with no caller call, so a test reads the captures
/// while such a submission runs.
final class MountCallingBackend: LanguageModelSessionBackend {
    /// The prefix of the answer of each submission after the first.
    static let answerPrefix = "answered from: "

    /// The fields a submission writes and a test reads.
    private struct Captures {
        /// See ``MountCallingBackend/receivedPrompts``.
        var receivedPrompts: [String] = []

        /// See ``MountCallingBackend/toolOutputs``.
        var toolOutputs: [String] = []
    }

    /// The stub that records the transcript entries of each submission.
    private let inner = StubSessionBackend()

    /// The composed tool list of the session.
    private let tools: [any Tool]

    /// The calls of the first submission, in order.
    private let calls: [ScriptedMountCall]

    /// The one lock the captures are behind.
    private let captures = Mutex(Captures())

    /// Every prompt this backend got, in submission order.
    var receivedPrompts: [String] { captures.withLock { $0.receivedPrompts } }

    /// The output of each scripted call, in call order.
    var toolOutputs: [String] { captures.withLock { $0.toolOutputs } }

    /// Makes a backend over `tools` that makes `calls` in its first
    /// submission.
    ///
    /// - Parameters:
    ///   - tools: The composed tool list of the session.
    ///   - calls: The calls of the first submission, in order.
    init(tools: [any Tool], calls: [ScriptedMountCall]) {
        self.tools = tools
        self.calls = calls
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let isFirstSubmission = captures.withLock { captures in
            captures.receivedPrompts.append(prompt)
            return captures.receivedPrompts.count == 1
        }
        _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
        guard isFirstSubmission else {
            return Self.answerPrefix + prompt
        }
        var lastOutput = ""
        for call in calls {
            lastOutput = try await self.call(call)
            captures.withLock { [lastOutput] in $0.toolOutputs.append(lastOutput) }
        }
        return lastOutput
    }

    /// Makes one scripted call through the composed tool that it names.
    ///
    /// - Parameter call: The call.
    /// - Returns: The output of the tool.
    /// - Throws: ``UnknownScriptedTool`` when no composed tool has the name,
    ///   and what the arguments decoding or the tool throws.
    private func call(_ call: ScriptedMountCall) async throws -> String {
        guard let tool = tools.first(where: { $0.name == call.toolName }) else {
            throw UnknownScriptedTool(toolName: call.toolName)
        }
        return try await Self.invoke(tool, argumentsJSON: call.argumentsJSON)
    }

    /// Decodes `argumentsJSON` into the arguments of `tool` and calls it.
    ///
    /// - Parameters:
    ///   - tool: The composed tool.
    ///   - argumentsJSON: The arguments, as a JSON object.
    /// - Returns: The output of the tool, as text.
    /// - Throws: What the arguments decoding or the tool throws.
    private static func invoke<T: Tool>(_ tool: T, argumentsJSON: String) async throws -> String {
        let arguments = try T.Arguments(GeneratedContent(json: argumentsJSON))
        return String(describing: try await tool.call(arguments: arguments))
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        inner.streamResponse(to: prompt, maxTokens: maxTokens)
    }

    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await inner.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    func makeFork() -> any LanguageModelSessionBackend {
        inner.makeFork()
    }

    func transcriptEntries() -> [Transcript.Entry] {
        inner.transcriptEntries()
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        inner.usageTokenCounts()
    }
}

/// Vends one ``MountCallingBackend`` for each session, over the composed
/// tool list that `makeSession` passes, and keeps the last one for the test.
final class MountCallingLLMContainer: LoadedLLMContainer {
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The calls that the first submission of each vended backend makes.
    private let calls: [ScriptedMountCall]

    /// The backend the last vend made, behind a lock, because the vend and
    /// the read of the test can run on different tasks.
    private let vended = Mutex<MountCallingBackend?>(nil)

    /// The backend the last vend made, or `nil` before the first vend.
    var lastBackend: MountCallingBackend? { vended.withLock { $0 } }

    /// Makes a container whose backends make `calls` in their first
    /// submission.
    ///
    /// - Parameter calls: The calls of the first submission, in order.
    init(calls: [ScriptedMountCall]) {
        self.calls = calls
    }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        let backend = MountCallingBackend(tools: tools, calls: calls)
        vended.withLock { $0 = backend }
        return backend
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(entries: Array(transcript))
    }
}
