import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization

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

/// The backend the background-run suites drive: its first call calls every
/// composed ``LatchedBackgroundToolRunner`` — each of which backgrounds its call —
/// and answers with the last pending envelope; every later call answers
/// ``answerPrefix`` plus the prompt it was given, so an answer grounded in
/// settled results is provable by reading the answer.
///
/// Every mutable field is behind one `Mutex`. The pump of the owning session
/// drives one backend method at a time, but it delivers a settled run in a
/// submission of its own, with no caller call (task ^3qx0mpt), so a test can
/// read the captures while such a submission runs.
final class BackgroundingBackend: LanguageModelSessionBackend {
    /// The prefix the answer of every call after the first opens with, so a
    /// test can tell a delivery submission's answer from the pending envelope
    /// of the first call.
    static let answerPrefix = "answered from: "

    /// The fields a call writes and a test reads.
    private struct Captures {
        /// See ``BackgroundingBackend/receivedPrompts``.
        var receivedPrompts: [String] = []

        /// See ``BackgroundingBackend/toolCallCount``.
        var toolCallCount = 0

        /// See ``BackgroundingBackend/toolOutputs``.
        var toolOutputs: [String] = []
    }

    private let inner = StubSessionBackend()

    /// The session's own composed tool list.
    private let tools: [any Tool]

    /// Holds the first answer open after its tool calls until a test opens
    /// it, or `nil` to let that answer return at once.
    private let holdFirstAnswer: RunLatch?

    /// The one lock the captures are behind.
    private let captures = Mutex(Captures())

    /// Every prompt this backend was asked to respond to, in call order.
    var receivedPrompts: [String] { captures.withLock { $0.receivedPrompts } }

    /// How many composed tool calls this backend made, across every call.
    var toolCallCount: Int { captures.withLock { $0.toolCallCount } }

    /// What each composed tool call handed back to the model, in call order.
    var toolOutputs: [String] { captures.withLock { $0.toolOutputs } }

    /// Creates a backend over `tools`.
    ///
    /// - Parameters:
    ///   - tools: The session's composed tool list.
    ///   - holdFirstAnswer: A latch that holds the first answer open after its
    ///     tool calls, or `nil`.
    init(tools: [any Tool], holdFirstAnswer: RunLatch? = nil) {
        self.tools = tools
        self.holdFirstAnswer = holdFirstAnswer
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        let isFirstCall = captures.withLock { captures in
            captures.receivedPrompts.append(prompt)
            return captures.toolCallCount == 0
        }
        _ = try await inner.respond(to: prompt, maxTokens: maxTokens)
        guard isFirstCall else {
            return Self.answerPrefix + prompt
        }
        var rendered = ""
        for tool in tools {
            guard
                let mounted = ToolFailureDelivery.throwingTool(of: tool)
                    as? BackgroundToolRunner<BackgroundFixtureArguments>
            else { continue }
            captures.withLock { $0.toolCallCount += 1 }
            rendered = try await mounted.call(arguments: BackgroundFixtureArguments(value: prompt))
            captures.withLock { [rendered] in $0.toolOutputs.append(rendered) }
        }
        await holdFirstAnswer?.waitUntilOpen()
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
    /// The scripted counter of this container: one token per `Character`.
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    /// The backend the last vend produced.
    private(set) var lastBackend: BackgroundingBackend?

    /// Handed to every vended backend as its first-answer hold.
    private let holdFirstAnswer: RunLatch?

    /// Creates a container.
    ///
    /// - Parameter holdFirstAnswer: A latch every vended backend holds its
    ///   first answer open on, or `nil`.
    init(holdFirstAnswer: RunLatch? = nil) {
        self.holdFirstAnswer = holdFirstAnswer
    }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        let backend = BackgroundingBackend(tools: tools, holdFirstAnswer: holdFirstAnswer)
        lastBackend = backend
        return backend
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        StubSessionBackend(entries: Array(transcript))
    }
}
