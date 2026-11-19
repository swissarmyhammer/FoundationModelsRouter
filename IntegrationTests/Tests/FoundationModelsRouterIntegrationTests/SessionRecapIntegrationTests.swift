import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The recap prompt of D206 on a bundled flash model: the recapper of a
/// session directory makes one recap call on the real model after a turn
/// with tool calls, and the recap is one sentence of at most 200
/// characters.
///
/// The model is Qwen 3.8 27B in 4 bits, the flash model of a bundled profile.
/// The recapper runs as the directory runs it: its host gives the `flash`
/// slot of a profile over the loaded model, and a manual clock ends the idle
/// time.
@Suite(
    "Gated real-model integration: the recap prompt on the bundled flash model",
    .serialized,
    .exclusiveRealModel
)
struct SessionRecapIntegrationTests {
    /// The recaps that the host of the recapper got, in order.
    private final class WriteLog: Sendable {
        /// The recaps, behind one lock: the recapper writes from a task of
        /// its own.
        private let recaps = Mutex<[String]>([])

        /// The recaps so far.
        var all: [String] { recaps.withLock { $0 } }

        /// Records `recap`.
        ///
        /// - Parameter recap: One written recap.
        func record(_ recap: String) {
            recaps.withLock { $0.append(recap) }
        }
    }

    /// The flash model of a bundled profile, 4-bit.
    private static let flashModel: ModelRef = "mlx-community/Qwen3.8-27B-4bit"

    /// The user prompts of the turn.
    private static let prompts = [
        "The parser test testNestedArrays fails since the last change. Find the cause and fix it.",
        "Also add a test for an empty array.",
    ]

    /// The tool calls of the turn: a read, an edit and a test run.
    private static let toolCalls = [
        ToolCallEntry(
            id: "call-1", name: "read_file", argumentsJSON: #"{"path":"Sources/Parser/ArrayParser.swift"}"#,
            status: .completed, summary: nil),
        ToolCallEntry(
            id: "call-2", name: "edit_file", argumentsJSON: #"{"path":"Sources/Parser/ArrayParser.swift"}"#,
            status: .completed, summary: nil),
        ToolCallEntry(
            id: "call-3", name: "edit_file", argumentsJSON: #"{"path":"Tests/ParserTests/ArrayParserTests.swift"}"#,
            status: .completed, summary: nil),
        ToolCallEntry(
            id: "call-4", name: "run_command", argumentsJSON: #"{"command":"swift test --filter ArrayParserTests"}"#,
            status: .completed, summary: nil),
    ]

    /// The final reply of the turn.
    private static let reply = """
        The nested array parser skipped the closing bracket of an inner array, so the outer array \
        ended too early. I fixed the index step in ArrayParser.swift and added testEmptyArray. \
        All 14 parser tests pass now.
        """

    /// The characters that end a sentence.
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "\u{3002}", "\u{FF01}", "\u{FF1F}"]

    /// The number of sentences of `text`: the parts after each sentence end
    /// that is followed by white space and more text.
    ///
    /// - Parameter text: One recap.
    /// - Returns: The number of sentences.
    private static func sentenceCount(of text: String) -> Int {
        let characters = Array(text)
        let breaks = characters.indices.dropLast().filter { index in
            sentenceEnds.contains(characters[index]) && characters[index + 1].isWhitespace
        }
        return breaks.count + 1
    }

    /// Runs one turn with tool calls through a recapper over the `flash`
    /// slot of `profile`, ends the idle time, and gives the written recaps.
    ///
    /// - Parameter profile: The profile over the loaded model.
    /// - Returns: The recaps that the recapper wrote.
    private static func recaps(over profile: LanguageModelProfile) async -> [String] {
        let clock = ManualRunClock()
        let recapper = SessionRecapper(clock: clock)
        let writes = WriteLog()
        let target = SessionRecapper.Target(
            model: SessionRecapModel(flash: profile.flash, tracer: nil), previousRecap: nil)
        recapper.use(
            host: SessionRecapper.Host(
                target: { _ in target }, isModelBusy: { _ in false },
                write: { recap, _, _ in writes.record(recap) }))
        let session = ULID.generate()
        recapper.observe(.workStarted, of: session, isIdle: false, getsRecap: true)
        recapper.noteDelivered(prompts.map { DeliveredPrompt(mail: MailID(), text: $0) }, of: session)
        recapper.observe(
            .answered(
                SessionAnswer(
                    reply: reply, mailIds: [], usage: nil, compactions: [], toolCalls: toolCalls,
                    toolInvocations: [])),
            of: session, isIdle: false, getsRecap: true)
        recapper.observe(.workEnded, of: session, isIdle: true, getsRecap: true)
        clock.advance(by: SessionRecapper.idleTime)
        _ = await recapper.jobChanges.waitUntil { recapper.jobCount == 0 }
        return writes.all
    }

    @Test("the recap of a turn with tool calls is one sentence of at most 200 characters")
    func theRecapIsOneShortSentence() async throws {
        let container = try await RealModelContainer.load(ref: Self.flashModel, samplingMode: .greedy)
        // The weights go back also when the test throws (rule T1).
        defer { await container.evict() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRecapIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let profile = RealModelHarness.make(
            model: Self.flashModel, context: ScriptedSessionContext.tokens, container: container.container,
            samplingMode: container.samplingMode, cacheDir: directory, recordingsDir: directory)

        let recap = try #require(await Self.recaps(over: profile).first)

        // The gated run's record of the recap. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print("[sessionRecap] \(Self.flashModel.stringValue) recap=\(recap)")
        #expect(recap.count <= SessionRecapOutput.characterLimit)
        #expect(Self.sentenceCount(of: recap) == 1)
    }
}
