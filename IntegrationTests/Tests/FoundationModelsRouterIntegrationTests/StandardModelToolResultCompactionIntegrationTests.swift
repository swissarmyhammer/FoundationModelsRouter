import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// Case 2 of the compaction suite: one tool call on each standard model whose
/// result crosses the compaction trigger (tasks ^9ddjkjm and ^yyjvyga).
///
/// The test is an extension of `StandardModelCompactionIntegrationTests`, so it
/// shares the one load of the model with the other two cases.
///
/// The session window is a small test number. The prompt is one short
/// request, under the trigger. The one tool returns a result of a few hundred
/// tokens that takes the context over the trigger. The test drives one
/// answer: the model calls the tool, the session compacts at the tool-result
/// boundary, and a continuation of the same answer replies. The count of
/// tool calls is not the subject of this test.
///
/// The test sizes the tool result with the model's own tokenizer, as a share
/// of the window.
extension StandardModelCompactionIntegrationTests {
    /// The small session window of the tool-result test, in tokens.
    private static let toolResultWindow = 2048

    /// The share of ``toolResultWindow`` at which the tool-result test
    /// compacts. The short prompt is under it, and the prompt with the tool
    /// result is over it.
    private static let toolResultTriggerShare = 0.25

    /// The window and the budget of the tool-result test on `model`: the
    /// limit is the small window, grown for an always-reasoning model
    /// (``CompactionTestWindow``). The target is the trigger's own share. The
    /// instructions carry the tool definition, and a smaller target left no
    /// room for a summary after them (run of 2026-09-23: shortfall
    /// `targetLeavesNoRoomForSummary` at a target of 0.1).
    private static func toolResultWindow(for model: RealModelContainer) async throws -> CompactionTestWindow {
        try await CompactionTestWindow(
            model: model, baseWindow: toolResultWindow, triggerShare: toolResultTriggerShare)
    }

    /// The share of the stated window the tool result fills: the trigger's own
    /// share, so the result alone reaches the trigger. It is a share of
    /// ``toolResultWindow``, so the result counts the same tokens on every
    /// model.
    private static let resultShare = toolResultTriggerShare

    /// The key the tool result holds.
    private static let recordKey = "KESTREL-42"

    /// The name of the one tool.
    fileprivate static let toolName = "lookup_record"

    /// The request of the one answer. It does not turn reasoning off: the run of
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

    @Test(
        "a tool call triggers a compaction: one compaction inside the answer, a smaller snapshot, and a reply",
        arguments: StandardModels.all)
    func toolResultTriggersCompaction(model: ModelRef) async throws {
        let loaded = try await ResidentStandardModel.shared.container(for: model)
        let counter = loaded.container.tokenCounter
        let listing =
            Self.lines(
                { "Record line \($0): inventory batch checked, status nominal, no action needed." },
                filling: Self.resultShare, counter: counter) + "Record key: \(Self.recordKey)."
        let window = try await Self.toolResultWindow(for: loaded)
        let harness = try StandardModelSessionHarness(model: model, container: loaded, window: window.tokens)
        defer { harness.removeDirectory() }
        let tool = RecordTool(listing: listing)
        let session = harness.profile.standard.makeSession(
            instructions: Self.instructions, tools: [tool], budget: window.budget)

        let record = try await StandardModelAnswerRecord.drive(session, prompt: Self.toolResultRequest)
        record.report(
            label: standardModelCompactionLabel,
            detail: """
                \(model.stringValue) case 2 toolCalls=\(tool.calls) resultTokens=\(counter.count(listing)) \
                window=\(window.tokens) trigger=\(window.budget.triggerTokens)
                """)

        #expect(tool.calls >= 1, "the model did not call the tool")
        try Self.expectOneCompactionAndAnAnswer(record, holding: Self.recordKey)
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
    let name = StandardModelCompactionIntegrationTests.toolName
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
