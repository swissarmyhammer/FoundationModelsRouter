import Foundation
import FoundationModels

@testable import FoundationModelsRouter

/// The argument schema every latched background fixture tool takes: one
/// string, the smallest surface the tool-wiring suites use.
@Generable
struct BackgroundFixtureArguments {
    let value: String
}

/// The failure a ``LatchedBackgroundToolRunner`` built with `fails: true` throws
/// once its latch opens.
struct LatchedToolFailure: Error {}

/// A tool that declares background for itself, holds its body on a
/// ``RunLatch`` until a test opens it, and then settles the way the test
/// chose: with `output`, with a thrown ``LatchedToolFailure``, or — when a
/// `timeout` is set and the latch stays shut — by that timeout.
struct LatchedBackgroundToolRunner: Tool, BackgroundTool {
    let name: String
    let description = "test-only slow tool that declares background"

    /// The latch this tool's body waits on before producing its output.
    let gate: RunLatch

    /// The output the body returns once the latch opens.
    let output: String

    /// Whether the body throws ``LatchedToolFailure`` instead of returning.
    var fails = false

    /// The run's no-progress timeout, or `nil` for none.
    var timeout: TimeInterval? = nil

    var mount: ToolMount? {
        ToolMount(mode: .background, timeout: timeout)
    }

    func call(arguments: BackgroundFixtureArguments) async throws -> String {
        await gate.waitUntilOpen()
        if fails { throw LatchedToolFailure() }
        return output
    }
}

/// The backend the background-run suites drive: its first turn calls every
/// composed ``LatchedBackgroundToolRunner`` — each of which backgrounds its call —
/// and answers with the last pending envelope; every later turn answers
/// ``answerPrefix`` plus the prompt it was given, so an answer grounded in
/// drained results is provable by reading the answer.
///
/// `@unchecked Sendable` on the same terms as ``StubSessionBackend``: the
/// owning session drives one backend method at a time (its turn lock
/// serializes turns), and a test reads the captures only after the driving
/// call returned.
final class BackgroundingBackend: LanguageModelSessionBackend, @unchecked Sendable {
    /// The prefix every non-first turn's answer opens with, so a test can
    /// tell a drained continuation turn's answer from the first turn's
    /// pending envelope.
    static let answerPrefix = "answered from: "

    private let inner = StubSessionBackend()

    /// The session's own composed tool list.
    private let tools: [any Tool]

    /// Holds the first turn open after its tool calls until a test opens it,
    /// or `nil` to let that turn return at once.
    private let holdFirstTurn: RunLatch?

    /// Every prompt this backend was asked to respond to, in turn order.
    private(set) var receivedPrompts: [String] = []

    /// How many composed tool calls this backend made, across every turn.
    private(set) var toolCallCount = 0

    /// What each composed tool call handed back to the model, in call order.
    private(set) var toolOutputs: [String] = []

    /// Creates a backend over `tools`.
    ///
    /// - Parameters:
    ///   - tools: The session's composed tool list.
    ///   - holdFirstTurn: A latch that holds the first turn open after its
    ///     tool calls, or `nil`.
    init(tools: [any Tool], holdFirstTurn: RunLatch? = nil) {
        self.tools = tools
        self.holdFirstTurn = holdFirstTurn
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        receivedPrompts.append(prompt)
        _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
        guard toolCallCount == 0 else {
            return Self.answerPrefix + prompt
        }
        var rendered = ""
        for tool in tools {
            guard let mounted = tool as? BackgroundToolRunner<BackgroundFixtureArguments> else { continue }
            toolCallCount += 1
            rendered = try await mounted.call(arguments: BackgroundFixtureArguments(value: prompt))
            toolOutputs.append(rendered)
        }
        await holdFirstTurn?.waitUntilOpen()
        return rendered
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(try await self.respond(to: prompt, maxTokens: maxTokens))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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

/// Vends one retained ``BackgroundingBackend`` per session, handing it the
/// composed tool list `makeSession` threaded through.
///
/// `@unchecked Sendable` invariant: `lastBackend` is written once,
/// synchronously, inside `makeSession(instructions:tools:)` — itself called
/// synchronously from `RoutedModel.makeSession` on the vending thread — and
/// read only by the `@MainActor` test method after that vend returns.
final class BackgroundingLLMContainer: LoadedLLMContainer, @unchecked Sendable {
    /// The backend the last vend produced.
    private(set) var lastBackend: BackgroundingBackend?

    /// Handed to every vended backend as its first-turn hold.
    private let holdFirstTurn: RunLatch?

    /// Creates a container.
    ///
    /// - Parameter holdFirstTurn: A latch every vended backend holds its
    ///   first turn open on, or `nil`.
    init(holdFirstTurn: RunLatch? = nil) {
        self.holdFirstTurn = holdFirstTurn
    }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        let backend = BackgroundingBackend(tools: tools, holdFirstTurn: holdFirstTurn)
        lastBackend = backend
        return backend
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(entries: Array(transcript))
    }
}
