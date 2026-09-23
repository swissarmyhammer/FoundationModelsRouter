import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// Case 2 of the compaction suite: one tool call on Qwen 3.8 27B whose result
/// crosses the compaction trigger (tasks ^9ddjkjm and ^yyjvyga).
///
/// The test is an extension of `Qwen38CompactionIntegrationTests`, so it
/// shares the one load of the model with the other two cases.
///
/// The session window is a small test number. The prompt is one short
/// request, under the trigger. The one tool returns a result of a few hundred
/// tokens that takes the context over the trigger. The turn is one turn: the
/// model calls the tool, the session compacts at the tool-result boundary,
/// and the same turn answers. The count of tool calls is not the subject of
/// this test.
///
/// The test sizes the tool result with the model's own tokenizer, as a share
/// of the window.
extension Qwen38CompactionIntegrationTests {
    /// The small session window of the tool-result test, in tokens.
    private static let toolResultWindow = 2048

    /// The budget of the tool-result test: its limit is the small window.
    /// The short prompt is under the trigger, and the prompt with the tool
    /// result is over it. The target is the trigger's own share. The
    /// instructions carry the tool definition, and a smaller target left no
    /// room for a summary after them (run of 2026-09-23: shortfall
    /// `targetLeavesNoRoomForSummary` at a target of 0.1).
    private static let toolResultBudget = TokenBudget(limit: toolResultWindow, trigger: 0.25, target: 0.25)

    /// The share of the window the tool result fills.
    private static let resultShare = 0.25

    /// The key the tool result holds.
    private static let recordKey = "KESTREL-42"

    /// The name of the one tool.
    fileprivate static let toolName = "lookup_record"

    /// The request of the one turn. It does not turn reasoning off: the run of
    /// 2026-09-23 with the Qwen 3 `/no_think` switch took 32.4 s against
    /// 20.7 s without it.
    private static let toolResultRequest =
        "Call `\(toolName)` with record \"archive\" one time. Then tell me the record key it returns."

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
        let goal = Int(Double(toolResultWindow) * share)
        var text = ""
        var index = 1
        while counter.count(text) < goal {
            text += line(index) + "\n"
            index += 1
        }
        return text
    }

    @Test("a tool call triggers a compaction: one compaction inside the turn, a smaller snapshot, and an answer")
    func toolResultTriggersCompaction() async throws {
        let loaded = try await Qwen38ResidentModel.shared.container()
        let counter = loaded.container.tokenCounter
        let listing =
            Self.lines(
                { "Record line \($0): inventory batch checked, status nominal, no action needed." },
                filling: Self.resultShare, counter: counter) + "Record key: \(Self.recordKey)."
        let harness = try Qwen38SessionHarness(container: loaded, window: Self.toolResultWindow)
        defer { harness.removeDirectory() }
        let tool = RecordTool(listing: listing)
        let session = harness.profile.standard.makeSession(
            instructions: Self.instructions, tools: [tool], budget: Self.toolResultBudget)

        let turn = try await Qwen38TurnRecord.drive(session, prompt: Self.toolResultRequest)
        turn.print(
            label: qwen38CompactionLabel,
            detail: """
                case 2 toolCalls=\(tool.calls) resultTokens=\(counter.count(listing)) \
                trigger=\(Self.toolResultBudget.triggerTokens)
                """)

        #expect(tool.calls >= 1, "the model did not call the tool")
        try Self.expectOneCompactionAndAnAnswer(turn)
    }
}

/// The arguments of the one tool.
@Generable
struct RecordArguments {
    /// The record to look up.
    let record: String
}

/// The one tool of the tool-result test: it returns its fixed record listing.
final class RecordTool: FoundationModels.Tool, Sendable {
    let name = Qwen38CompactionIntegrationTests.toolName
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
