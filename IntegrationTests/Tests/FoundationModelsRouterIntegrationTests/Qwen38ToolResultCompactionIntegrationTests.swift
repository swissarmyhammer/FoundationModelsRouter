import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model of this suite: the product's standard model, Qwen 3.8 27B in the
/// `mxfp4` quantization.
private let qwen38ToolResultModel: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

/// The tag every printed line of this suite carries.
private let qwen38ToolResultLabel = "qwen38ToolResultCompaction"

/// One tool call on Qwen 3.8 27B whose result crosses the compaction trigger
/// (task ^9ddjkjm).
///
/// The session window is small on purpose. The prompt fills the context to a
/// point under the trigger, and the one tool returns a result that takes the
/// context over it. The turn is one turn: the model calls the tool once, the
/// session compacts at the tool-result boundary, and the same turn answers.
///
/// The test sizes the prompt and the tool result with the model's own
/// tokenizer, as fractions of the window. Sizes by line count missed the
/// trigger band in the first runs of 2026-09-23.
@Suite(
    "Gated real-model test: a tool call can trigger a compaction on Qwen 3.8 27B (task ^9ddjkjm)",
    .serialized,
    .exclusiveRealModel
)
struct Qwen38ToolResultCompactionIntegrationTests {
    /// The small session window of this test, in tokens.
    private static let window = 16_384

    /// The budget of the session: its limit is the small window.
    private static let budget = TokenBudget(limit: window, trigger: 0.6, target: 0.3)

    /// The share of the window the prompt fills: under the trigger.
    private static let promptShare = 0.45

    /// The share of the window the tool result fills. With the prompt, it
    /// takes the context over the trigger, and it leaves room under the
    /// window for the summarizer call.
    private static let resultShare = 0.25

    /// The key the tool result holds.
    private static let recordKey = "KESTREL-42"

    /// The name of the one tool.
    private static let toolName = "lookup_record"

    /// The instructions of the session.
    private static let instructions = """
        You are a terse, literal assistant. You have one tool, `\(toolName)`. \
        Call it exactly one time, then answer in one short sentence.
        """

    /// The request at the end of the prompt.
    private static let request =
        "\n\nCall `\(toolName)` with record \"archive\" one time. Then tell me the record key it returns."

    /// Numbered lines of `line`, as many as it takes to count `share` of the
    /// window with `counter`.
    ///
    /// - Parameters:
    ///   - line: Makes the line of an index.
    ///   - share: The share of the window the lines fill.
    ///   - counter: The model's own token counter.
    /// - Returns: The lines, joined with newlines.
    private static func lines(
        _ line: (Int) -> String, filling share: Double, counter: any TokenCounter
    ) -> String {
        let goal = Int(Double(window) * share)
        var text = ""
        var index = 1
        while counter.count(text) < goal {
            text += line(index) + "\n"
            index += 1
        }
        return text
    }

    /// The arguments of the tool.
    @Generable
    struct RecordArguments {
        /// The record to look up.
        let record: String
    }

    /// The one tool: it returns its fixed record listing.
    final class RecordTool: FoundationModels.Tool, Sendable {
        let name = Qwen38ToolResultCompactionIntegrationTests.toolName
        let description = "Looks up an archive record and returns its full listing."

        /// The listing every call returns.
        private let listing: String

        /// How many times the model called the tool.
        private let callCount = Mutex(0)

        /// Makes the tool.
        ///
        /// - Parameter listing: The listing every call returns.
        init(listing: String) {
            self.listing = listing
        }

        /// How many times the model called the tool.
        var calls: Int {
            callCount.withLock { $0 }
        }

        func call(arguments: RecordArguments) async throws -> String {
            callCount.withLock { $0 += 1 }
            return listing
        }
    }

    @Test("a tool result crosses the trigger: one compaction inside the turn, a smaller snapshot, and an answer")
    func toolCallTriggersCompaction() async throws {
        let wallClock = ContinuousClock.now
        let container = try await RealModelContainer.load(ref: qwen38ToolResultModel, samplingMode: .greedy)
        let counter = container.container.tokenCounter
        let prompt =
            Self.lines(
                { "Background note \($0): the archive team keeps each record in order." },
                filling: Self.promptShare, counter: counter) + Self.request
        let listing =
            Self.lines(
                { "Record line \($0): inventory batch checked, status nominal, no action needed." },
                filling: Self.resultShare, counter: counter) + "Record key: \(Self.recordKey)."
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Qwen38ToolResultCompaction-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = RealModelHarness.make(
            model: qwen38ToolResultModel, context: Self.window, container: container.container,
            samplingMode: container.samplingMode, cacheDir: directory, recordingsDir: directory)
        defer { withExtendedLifetime(profile) {} }
        let tool = RecordTool(listing: listing)
        let session = profile.standard.makeSession(
            instructions: Self.instructions, tools: [tool], budget: Self.budget)

        var compactions: [CompactionResult] = []
        var answerAfterCompaction = ""
        for try await event in await session.streamEvents(to: prompt, maxTokens: nil) {
            switch event {
            case .compaction(let result):
                compactions.append(result)
            case .textDelta(let text) where !compactions.isEmpty:
                answerAfterCompaction += text
            default:
                break
            }
        }
        await container.container.model.evict()

        // The gated run's record for the card: a reader copies these lines. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print(
            """
            [\(qwen38ToolResultLabel)] wallClock=\(ContinuousClock.now - wallClock) toolCalls=\(tool.calls) \
            promptTokens=\(counter.count(prompt)) resultTokens=\(counter.count(listing)) \
            trigger=\(Self.budget.triggerTokens) \
            compactions=\(compactions.map { "\($0.tokensBefore)->\($0.tokensAfter)" })
            [\(qwen38ToolResultLabel)] summary:\n\(compactions.first?.summary ?? "<none>")
            [\(qwen38ToolResultLabel)] answer: \(answerAfterCompaction.debugDescription)
            """)

        #expect(tool.calls == 1, "the model called the tool \(tool.calls) times")
        #expect(compactions.count == 1, "expected one compaction inside the turn, got \(compactions.count)")
        let compaction = try #require(compactions.first)
        #expect(compaction.summary != nil, "no summary applied: shortfall \(String(describing: compaction.shortfall))")
        #expect(
            compaction.tokensAfter < compaction.tokensBefore,
            "the snapshot counts \(compaction.tokensAfter) tokens against \(compaction.tokensBefore) before")
        #expect(
            !answerAfterCompaction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the turn wrote no answer after the compaction")
    }
}
