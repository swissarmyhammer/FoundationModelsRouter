import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^ssv41m9: the summarizer call of a
/// compaction on the own model of the session has no tools.
///
/// Each session runs over the production backend and a real
/// `LanguageModelSession` over a ``SummarizerToolCallModel``, with no GPU.
/// The session mounts one tool, ``CountingTool``. The flash slot of the
/// profile is a stub that fails, so each compaction falls back to the own
/// model of the session. Each pass of the model records the names of the
/// tools that the SDK gives it.
@Suite("The own-model summarizer call has no tools (task ^ssv41m9)")
struct SummarizerToolsTests {
    /// The suite's temp-directory prefix, handed to
    /// ``RouterTestFixtures/makeTempDir(prefix:)``.
    private static let tempDirPrefix = "SummarizerToolsTests"

    /// The budget of each compaction: its target is far under
    /// ``SummarizerToolCallModel/callerPrompt``, so the compaction applies.
    private static let budget = TokenBudget(limit: 400, trigger: 0.8, target: 0.5)

    /// A session over one ``SummarizerToolCallModel`` that mounts one
    /// ``CountingTool``.
    private struct Fixture {
        /// The log of the model.
        let log: SummarizerToolCallLog

        /// The count of the tool body runs.
        let toolRuns: ToolRunCount

        /// The session. It mounts the tool.
        let session: any RoutedSession

        /// The directory of the router, which the test removes.
        let directory: URL
    }

    /// Makes a session over a new ``SummarizerToolCallModel``, whose flash
    /// slot fails, and sends the caller prompt to it.
    ///
    /// - Parameter callsTool: Whether the model calls the tool in a
    ///   summarizer pass.
    /// - Returns: The fixture.
    /// - Throws: What the resolution of the profile or the caller answer
    ///   throws. Before it throws, it removes the directory.
    private static func makeFixture(callsTool: Bool) async throws -> Fixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = SummarizerToolCallLog()
        let toolRuns = ToolRunCount()
        let container = LiveBackendContainer(model: SummarizerToolCallModel(log: log, callsTool: callsTool))
        return try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
            let router = RouterTestFixtures.makeRouter(
                cacheDir: directory,
                loader: PerSlotModelLoader(
                    standard: container,
                    flash: ConfiguredLLMContainer(responseText: "unused flash answer", shouldThrow: true),
                    dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let session = profile.standard.makeSession(
                configuration: SessionConfiguration(tools: [CountingTool(runs: toolRuns)]))
            _ = try await session.respond(to: SummarizerToolCallModel.callerPrompt)
            return Fixture(log: log, toolRuns: toolRuns, session: session, directory: directory)
        }
    }

    /// The production change that makes this test fail: an own-model
    /// summarizer backend that keeps the tools of the session. Its pass then
    /// sees the tool of the session.
    @Test("the own-model summarizer call gives the model no tools")
    func ownModelSummarizerCallHasNoTools() async throws {
        let fixture = try await Self.makeFixture(callsTool: false)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { await fixture.session.close() }

        let result = try await fixture.session.compactAndAwait(budget: Self.budget)

        #expect(result.summarizerTier == .ownModel)
        #expect(fixture.log.callerToolNames == [[CountingTool.toolName]])
        #expect(fixture.log.summarizerToolNames == [[]])
    }

    /// The production change that makes this test fail: an own-model
    /// summarizer backend that keeps the tools of the session. The SDK then
    /// runs the tool body, and the next pass writes the summary.
    ///
    /// With no tools, the SDK ends the call as it ends a call with an
    /// unknown tool. The own-model tier is the last tier, so the compaction
    /// fails.
    @Test("a tool call in the own-model summarizer call runs no tool body")
    func toolCallInOwnModelSummarizerCallRunsNoToolBody() async throws {
        let fixture = try await Self.makeFixture(callsTool: true)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        defer { await fixture.session.close() }

        await #expect(throws: CompactionDidNotComplete.self) {
            try await fixture.session.compactAndAwait(budget: Self.budget)
        }

        #expect(fixture.toolRuns.value == 0)
        #expect(fixture.log.summarizerToolNames == [[]])
    }
}

// MARK: - The tool

/// Counts the runs of the body of ``CountingTool``.
private final class ToolRunCount: Sendable {
    /// The count of runs.
    private let count = Mutex(0)

    /// The count of runs so far.
    var value: Int { count.withLock { $0 } }

    /// Adds one run.
    func record() {
        count.withLock { $0 += 1 }
    }
}

/// A tool whose body counts each run.
private struct CountingTool: Tool {
    /// The name of the tool.
    static let toolName = "counting_tool"

    let name = CountingTool.toolName
    let description = "counts each run of its body"

    /// The count the body adds to.
    let runs: ToolRunCount

    func call(arguments: MountArguments) async throws -> String {
        runs.record()
        return "counted: \(arguments.value)"
    }
}

// MARK: - The model

/// The passes of a ``SummarizerToolCallModel``.
private final class SummarizerToolCallLog: Sendable {
    /// One pass: whether the caller prompt started it, and the names of the
    /// tools that the SDK gave it.
    private struct Pass {
        /// Whether the caller prompt started the pass.
        let servesCaller: Bool

        /// The names of the tools of the pass, in order.
        let toolNames: [String]
    }

    /// The passes so far, in order.
    private let passes = Mutex<[Pass]>([])

    /// Records one pass.
    ///
    /// - Parameters:
    ///   - servesCaller: Whether the caller prompt started the pass.
    ///   - toolNames: The names of the tools of the pass.
    func record(servesCaller: Bool, toolNames: [String]) {
        passes.withLock { $0.append(Pass(servesCaller: servesCaller, toolNames: toolNames)) }
    }

    /// The tool names of each pass that the caller prompt started.
    var callerToolNames: [[String]] {
        passes.withLock { $0.filter(\.servesCaller).map(\.toolNames) }
    }

    /// The tool names of each other pass: the summarizer passes.
    var summarizerToolNames: [[String]] {
        passes.withLock { $0.filter { !$0.servesCaller }.map(\.toolNames) }
    }
}

/// A scripted `LanguageModel` that records the tools of each pass. It
/// answers the caller prompt with text. In a summarizer pass, it calls
/// ``CountingTool`` once when ``callsTool`` is `true`, and then writes a
/// short summary.
private struct SummarizerToolCallModel: LanguageModel {
    /// The caller prompt of each session. It fills the context over the
    /// target of the budget, so the compaction applies a summary.
    static let callerPrompt = String(repeating: "x", count: 600)

    /// The log each pass records into.
    let log: SummarizerToolCallLog

    /// Whether a summarizer pass calls the tool.
    let callsTool: Bool

    /// The model calls tools.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.toolCalling]) }

    /// The executor cache key: the identity of the log, and the script.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, callsTool: callsTool)
    }

    /// The executor that records the tools of each pass and answers.
    struct Executor: LanguageModelExecutor {
        /// The SDK's executor cache key. It compares the log by identity.
        struct Configuration: Sendable, Hashable {
            /// The log each pass records into.
            let log: SummarizerToolCallLog

            /// Whether a summarizer pass calls the tool.
            let callsTool: Bool

            /// Equal when both configurations name the same log and script.
            ///
            /// - Parameters:
            ///   - lhs: One configuration.
            ///   - rhs: The other configuration.
            /// - Returns: `true` when both hold the same log object and the
            ///   same script.
            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.callsTool == rhs.callsTool
            }

            /// Hashes by the `ObjectIdentifier` of the log and by the script.
            ///
            /// - Parameter hasher: The hasher to feed.
            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(callsTool)
            }
        }

        /// The model type this executor serves.
        typealias Model = SummarizerToolCallModel

        /// The token count each emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The configuration the SDK built this executor with.
        private let configuration: Configuration

        /// Stores `configuration`.
        ///
        /// - Parameter configuration: The log and the script.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the tools of the pass, and then calls the tool or answers.
        ///
        /// - Parameters:
        ///   - request: The generation request.
        ///   - model: The model. Unread: the log arrives through the
        ///     configuration.
        ///   - channel: The channel the pass emits into.
        /// - Throws: Never. `throws` comes from the protocol requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: SummarizerToolCallModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let entries = Array(request.transcript)
            let promptIndex = entries.lastIndex { entry in
                if case .prompt = entry { return true }
                return false
            }
            let servesCaller = promptIndex.map { index -> Bool in
                guard case .prompt(let prompt) = entries[index] else { return false }
                return WatchedText.text(of: prompt.segments) == SummarizerToolCallModel.callerPrompt
            } ?? false
            configuration.log.record(
                servesCaller: servesCaller, toolNames: request.enabledToolDefinitions.map(\.name))
            let calledTool = entries[(promptIndex.map { $0 + 1 } ?? 0)...].contains { entry in
                if case .toolCalls = entry { return true }
                return false
            }
            guard !servesCaller, configuration.callsTool, !calledTool else {
                await channel.send(.response(action: .appendText("ok", tokenCount: Self.emittedTokenCount)))
                return
            }
            await channel.send(
                .toolCalls(
                    entryID: "summarizer-tool-call",
                    action: .toolCall(
                        id: "summarizer-tool-call",
                        name: CountingTool.toolName,
                        action: .appendArguments(
                            GeneratedContent(properties: ["value": "summary"]).jsonString,
                            tokenCount: Self.emittedTokenCount))))
        }
    }
}
