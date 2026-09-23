import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model this suite compacts with: the product's standard model, Qwen 3.8
/// 27B in the `mxfp4` quantization.
private let qwen38CompactionModel: ModelRef = "mlx-community/Qwen3.8-27B-mxfp4"

/// The value the transcript plants in its tool output. The summary is printed,
/// so a reader can see whether it kept this value.
private let qwen38CompactionPlantedValue = "6543"

/// The tag every printed line of this suite carries.
private let qwen38CompactionLabel = "qwen38Compaction"

/// One compaction on Qwen 3.8 27B, over a live context this suite builds
/// directly (task ^dvyt1dx).
///
/// The suite generates no turn. It builds the entries in Swift: instructions,
/// one user prompt, one tool call, one tool output and one assistant reply.
/// Then it compacts them once. The only generation is the one summarizer call.
///
/// The test proves that the compaction works on this model. The summarizer
/// writes text, and the snapshot is smaller than the live context it
/// replaces. Before task ^dvyt1dx, the summarizer call ran with reasoning on,
/// and this model spent the whole ceiling of the call on its reasoning and
/// wrote no text. The call now turns reasoning off
/// (``LanguageModelSessionBackend/respondWithoutReasoning(to:maxTokens:)``).
@Suite(
    "Gated real-model smoke test: one compaction on Qwen 3.8 27B over a built live context (task ^dvyt1dx)",
    .serialized,
    .exclusiveRealModel
)
struct Qwen38CompactionIntegrationTests {
    /// The live context to compact: instructions, one user prompt, one tool
    /// call, one tool output and one assistant reply. No model wrote them.
    ///
    /// - Returns: The live context.
    /// - Throws: What `GeneratedContent(json:)` throws for the call's arguments.
    private static func builtLiveContext() throws -> Transcript {
        let instructions = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: "You are a terse, literal engineering assistant."))],
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
                        content: "The staging database listens on port \(qwen38CompactionPlantedValue)."))
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
        Host: staging-db.internal.example. Port: \(qwen38CompactionPlantedValue). Region: eu-west-2.
        Engine: PostgreSQL 16. Storage: 500 GB on encrypted volumes, with daily snapshots kept for fourteen days.
        Connection pool: the application servers share one pool; idle connections close after ten minutes.
        Maintenance window: Sundays from 02:00 to 04:00 UTC. The on-call engineer approves each restart.
        Backups: a full backup runs each night, and the restore test runs on the first Monday of each month.
        Access: engineers connect through the bastion host with their own keys; shared accounts are not allowed.
        Monitoring: alerts go to the database channel when replication lag is more than thirty seconds.
        Change policy: schema changes go through the migration pipeline, never by hand on the server.
        """

    @Test(
        "one compaction of a built live context on Qwen 3.8 27B: one summarizer call, a summary with text, and a snapshot smaller than the context it replaced"
    )
    func oneCompactionOnQwen38() async throws {
        let wallClock = ContinuousClock.now
        let transcript = try Self.builtLiveContext()

        let loaded = try await RealModelContainer.load(ref: qwen38CompactionModel, samplingMode: .greedy)
        let outcome = try await TranscriptCompaction.run(
            transcript, container: loaded, windowTokens: RealModels.context, label: qwen38CompactionLabel)
        await loaded.container.model.evict()

        let result = outcome.result
        print(
            "[\(qwen38CompactionLabel)] wallClock=\(ContinuousClock.now - wallClock) summary:\n\(result.summary ?? "<none>")"
        )

        // One summarizer call, and no other generation.
        #expect(outcome.ceilings.count == 1, "expected one summarizer call, got \(outcome.ceilings.count)")

        // The summarizer wrote text.
        let summary = try #require(
            result.summary, "no summary was applied: shortfall \(String(describing: result.shortfall))")
        #expect(!summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the summarizer wrote no text")

        // The compaction applied, and the snapshot is smaller than the live
        // context it replaced.
        #expect(result.stagesApplied == [Summarization.stageName])
        #expect(
            result.tokensAfter < result.tokensBefore,
            "the snapshot counts \(result.tokensAfter) tokens against \(result.tokensBefore) before"
        )
    }
}
