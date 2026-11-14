import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The value the built context plants in its tool output. The answer after
/// the compaction must hold it.
private let compactionPlantedValue = "6543"

/// The tag every printed line of this suite carries.
let standardModelCompactionLabel = "standardModelCompaction"

/// The three compaction cases on each model of ``StandardModels`` (tasks
/// ^dvyt1dx, ^9ddjkjm and ^yyjvyga), over one load of each model.
///
/// 1. We can compact: one compaction of a live context that the suite builds
///    directly. The only generation is the one summarizer call.
/// 2. A tool call triggers a compaction: inside one answer, a tool result
///    crosses the trigger, one compaction runs, and the same answer goes on.
///    This test is in `StandardModelToolResultCompactionIntegrationTests.swift`.
/// 3. A long context compacts: a small window and a seeded context over the
///    trigger at the start of an answer. The compaction runs before the first
///    submission of the answer, and the answer comes after it.
///
/// Each context is a few hundred tokens, and each window is a small test
/// number, so each test costs seconds after the load. ``ResidentStandardModel``
/// loads a model at the first test that asks for it, and the suite trait
/// evicts it as the suite ends.
///
/// Each test asserts the same four facts about its compaction: one
/// compaction, a summary with text, a snapshot smaller than the context it
/// replaced, and (for an answer) a reply that holds the planted value.
@Suite(
    "Gated real-model tests: the three compaction cases on each standard model (task ^yyjvyga)",
    .serialized,
    .exclusiveRealModel(whenSuiteEnds: { await ResidentStandardModel.shared.evict() })
)
struct StandardModelCompactionIntegrationTests {
    /// The instructions of the built context and of each session.
    static let instructions = "You are a terse, literal engineering assistant. Answer in one short sentence."

    /// The live context to compact: instructions, one user prompt, one tool
    /// call, one tool output and one assistant reply. No model wrote them.
    ///
    /// - Returns: The live context.
    /// - Throws: What `GeneratedContent(json:)` throws for the call's arguments.
    private static func builtLiveContext() throws -> Transcript {
        let instructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: Self.instructions))],
            toolDefinitions: []
        )
        let prompt = Transcript.Prompt(
            segments: [
                .text(Transcript.TextSegment(content: "Look up the staging database settings and tell me its port."))
            ]
        )
        let toolCalls = Transcript.ToolCalls([
            Transcript.ToolCall(
                id: "lookup-settings-1",
                toolName: "lookup_settings",
                arguments: try GeneratedContent(json: #"{"target":"staging-db"}"#)
            )
        ])
        let toolOutput = Transcript.ToolOutput(
            id: "lookup-settings-1",
            toolName: "lookup_settings",
            segments: [.text(Transcript.TextSegment(content: Self.settingsReport))]
        )
        let reply = Transcript.Response(
            assetIDs: [],
            segments: [
                .text(
                    Transcript.TextSegment(
                        content: "The staging database listens on port \(compactionPlantedValue)."))
            ]
        )
        return Transcript(entries: [
            .instructions(instructions), .prompt(prompt), .toolCalls(toolCalls), .toolOutput(toolOutput),
            .response(reply),
        ])
    }

    /// The text the tool call returned. It holds the planted value, and enough
    /// other settings that the live context is larger than a short summary.
    private static let settingsReport = """
        Settings report for staging-db.
        Host: staging-db.internal.example. Port: \(compactionPlantedValue). Region: eu-west-2.
        Engine: PostgreSQL 16. Storage: 500 GB on encrypted volumes, with daily snapshots kept for fourteen days.
        Connection pool: the application servers share one pool; idle connections close after ten minutes.
        Maintenance window: Sundays from 02:00 to 04:00 UTC. The on-call engineer approves each restart.
        Backups: a full backup runs each night, and the restore test runs on the first Monday of each month.
        Access: engineers connect through the bastion host with their own keys; shared accounts are not allowed.
        Monitoring: alerts go to the database channel when replication lag is more than thirty seconds.
        Change policy: schema changes go through the migration pipeline, never by hand on the server.
        """

    // MARK: - Case 3: the window of the answer-start test

    /// The small session window of the answer-start test, in tokens.
    private static let answerStartWindow = 2048

    /// The share of ``answerStartWindow`` at which the answer-start test
    /// compacts. It is far under the seeded context, so the context is over
    /// the trigger at the start of the answer.
    private static let answerStartTriggerShare = 0.1

    /// The window and the budget of the answer-start test on `model`. The
    /// target is the trigger's own share.
    private static func answerStartWindow(for model: RealModelContainer) async throws -> CompactionTestWindow {
        try await CompactionTestWindow(
            model: model, baseWindow: answerStartWindow, triggerShare: answerStartTriggerShare)
    }

    /// The prompt of the one answer of the answer-start test. It ends with the
    /// Qwen 3 switch that turns reasoning off for this message, so the answer
    /// costs a short reply and no reasoning. Flint has no such switch: it reads
    /// the switch as text and reasons.
    private static let answerStartPrompt = "Which port does the staging database listen on? /no_think"

    // MARK: - Case 1

    @Test(
        "we can compact: one compaction of a built live context, with one summarizer call, a summary with text, and a smaller snapshot",
        arguments: StandardModels.all
    )
    func oneCompactionOfABuiltContext(model: ModelRef) async throws {
        let transcript = try Self.builtLiveContext()
        let loaded = try await ResidentStandardModel.shared.container(for: model)
        let outcome = try await TranscriptCompaction.run(
            transcript, container: loaded, windowTokens: RealModels.context, label: standardModelCompactionLabel)
        let result = outcome.result
        // The gated run's record for the card: a reader copies this line. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        print("[\(standardModelCompactionLabel)] \(model.stringValue) case 1 summary:\n\(result.summary ?? "<none>")")

        #expect(outcome.ceilings.count == 1, "expected one summarizer call, got \(outcome.ceilings.count)")
        try Self.expectAppliedCompaction(result)
    }

    // MARK: - Case 3

    @Test(
        "a long context compacts: a seeded context over the trigger compacts one time before the answer, the snapshot is smaller, and the answer comes",
        arguments: StandardModels.all
    )
    func contextOverTheTriggerCompactsBeforeTheAnswer(model: ModelRef) async throws {
        let loaded = try await ResidentStandardModel.shared.container(for: model)
        let counter = loaded.container.tokenCounter
        let transcript = try Self.builtLiveContext()
        let seededTokens = try counter.count(transcript)
        let window = try await Self.answerStartWindow(for: loaded)
        try #require(
            seededTokens >= window.budget.triggerTokens,
            "the seeded context counts \(seededTokens) tokens, under the trigger of \(window.budget.triggerTokens)")

        let harness = try StandardModelSessionHarness(model: model, container: loaded, window: window.tokens)
        defer { harness.removeDirectory() }
        let session = harness.profile.standard.makeSession(
            instructions: Self.instructions, budget: window.budget)
        let actor = try #require(session as? RoutedSessionActor)
        await actor.seed(liveContext: transcript, measuredTokens: seededTokens)

        let record = try await StandardModelAnswerRecord.drive(session, prompt: Self.answerStartPrompt)
        record.report(label: standardModelCompactionLabel, detail: "\(model.stringValue) case 3 seededTokens=\(seededTokens)")

        #expect(record.textBeforeCompaction.isEmpty, "the answer wrote text before its compaction")
        try Self.expectOneCompactionAndAnAnswer(record, holding: compactionPlantedValue)
    }

    // MARK: - The shared assertions

    /// Asserts that `record` holds one applied compaction, and an answer after
    /// it that holds `plantedValue`.
    ///
    /// An answer that is not empty is not enough: before task ^5t72pdx, the
    /// summary kept the planted value, but the answer after the compaction
    /// said "I do not have access to your specific infrastructure
    /// configuration". The answer must use the compacted context.
    ///
    /// - Parameters:
    ///   - record: The record of the answer.
    ///   - plantedValue: The value the context planted, which the answer must hold.
    /// - Throws: When the answer holds no compaction.
    static func expectOneCompactionAndAnAnswer(_ record: StandardModelAnswerRecord, holding plantedValue: String) throws {
        #expect(record.compactions.count == 1, "expected one compaction in the answer, got \(record.compactions.count)")
        try expectAppliedCompaction(try #require(record.compactions.first))
        #expect(
            record.answer.contains(plantedValue),
            "the answer after the compaction does not hold \(plantedValue): \(record.answer.debugDescription)")
    }

    /// Asserts that `result` applied a summary with text and made the
    /// snapshot smaller than the context it replaced.
    ///
    /// - Parameter result: The compaction.
    /// - Throws: When the compaction applied no summary.
    static func expectAppliedCompaction(_ result: CompactionResult) throws {
        let summary = try #require(
            result.summary, "no summary was applied: shortfall \(String(describing: result.shortfall))")
        #expect(!summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the summarizer wrote no text")
        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(
            result.tokensAfter < result.tokensBefore,
            "the snapshot counts \(result.tokensAfter) tokens against \(result.tokensBefore) before")
    }
}

// MARK: - The window of a compaction test

/// The session window and the budget of one compaction test on one model.
///
/// Each compaction test states a small window and a trigger share of it, and
/// the window is a test number. An always-reasoning model (Flint) reasons in
/// its summarizer call, under ``ReasoningControl/thinkingAllowance`` on top of
/// the summary (task ^qmewzw0), and a small window has no room for that. So
/// for such a model the window grows by the allowance, and the trigger and
/// target shares shrink so that they keep their token counts: the test
/// compacts at the same context size on every model. Each other model keeps
/// the stated window and share.
struct CompactionTestWindow {
    /// The session window, in tokens.
    let tokens: Int

    /// The budget of the session: its limit is ``tokens``, and its target is
    /// its trigger.
    let budget: TokenBudget

    /// The window and the budget of a test that states `baseWindow` and
    /// `triggerShare`, on `model`.
    ///
    /// - Parameters:
    ///   - model: The loaded model.
    ///   - baseWindow: The window the test states, in tokens.
    ///   - triggerShare: The share of `baseWindow` at which the test compacts.
    /// - Throws: What the read of the reasoning control of the model throws.
    init(model: RealModelContainer, baseWindow: Int, triggerShare: Double) async throws {
        let control = try await model.container
            .makeSession(transcript: Transcript(entries: []), samplingMode: model.samplingMode)
            .reasoningControl()
        let allowance = control == .alwaysOn ? ReasoningControl.thinkingAllowance : 0
        tokens = baseWindow + allowance
        let share = triggerShare * Double(baseWindow) / Double(tokens)
        budget = TokenBudget(limit: tokens, trigger: share, target: share)
    }
}

// MARK: - The session and the answer of a compaction test

/// A profile over the resident model at a small window, and the temporary
/// directory it caches and records under.
struct StandardModelSessionHarness {
    /// The profile to vend sessions from.
    let profile: LanguageModelProfile

    /// The directory the profile caches and records under.
    private let directory: URL

    /// Makes the profile over `container` at `window`.
    ///
    /// - Parameters:
    ///   - model: The reference of the resident model.
    ///   - container: The resident model.
    ///   - window: The session window, in tokens. A test number.
    /// - Throws: What `FileManager.createDirectory` throws.
    init(model: ModelRef, container: RealModelContainer, window: Int) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StandardModelCompaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        profile = RealModelHarness.make(
            model: model, context: window, container: container.container,
            samplingMode: container.samplingMode, cacheDir: directory, recordingsDir: directory)
    }

    /// Removes the directory of the profile.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// What one answer of a compaction test produced.
struct StandardModelAnswerRecord {
    /// Every compaction of the answer, in order.
    var compactions: [CompactionResult] = []

    /// The text the answer wrote before its first compaction.
    var textBeforeCompaction = ""

    /// The text the answer wrote after its first compaction: the reply.
    var answer = ""

    /// Drives one answer of `session` and records its compactions and its text.
    ///
    /// - Parameters:
    ///   - session: The session.
    ///   - prompt: The prompt of the message.
    /// - Returns: The record of the answer.
    /// - Throws: What the answer throws.
    static func drive(_ session: any RoutedSession, prompt: String) async throws -> StandardModelAnswerRecord {
        var record = StandardModelAnswerRecord()
        for try await event in await session.streamEvents(to: prompt, maxTokens: nil) {
            switch event {
            case .compaction(let result):
                record.compactions.append(result)
            case .textDelta(let text) where record.compactions.isEmpty:
                record.textBeforeCompaction += text
            case .textDelta(let text):
                record.answer += text
            default:
                break
            }
        }
        return record
    }

    /// Writes the record for the card to the output of the gated run.
    ///
    /// - Parameters:
    ///   - label: The tag of the written lines.
    ///   - detail: The facts of the test that come before the record.
    func report(label: String, detail: String) {
        // The gated run's record for the card: a reader copies these lines. This test target does not ship.
        // swiftlint:disable:next no_direct_standard_out_logs - the gated run's record; this target does not ship
        Swift.print(
            """
            [\(label)] \(detail) compactions=\(compactions.map { "\($0.tokensBefore)->\($0.tokensAfter)" }) \
            shortfalls=\(compactions.map { String(describing: $0.shortfall) })
            [\(label)] summary:\n\(compactions.first?.summary ?? "<none>")
            [\(label)] answer: \(answer.debugDescription)
            """)
    }
}

// MARK: - Seeding a live context

extension RoutedSessionActor {
    /// Replaces the live context of this session with `liveContext`, and sets
    /// its measured usage to `measuredTokens`, as if earlier answers had built
    /// it.
    ///
    /// A test seeds a context this way so that it does not generate one.
    ///
    /// - Parameters:
    ///   - liveContext: The context the backend holds from now on.
    ///   - measuredTokens: The measured usage of that context.
    func seed(liveContext: Transcript, measuredTokens: Int) {
        backend = backend.replacingTranscript(liveContext)
        usageState = .measured(input: measuredTokens, output: 0)
    }
}
