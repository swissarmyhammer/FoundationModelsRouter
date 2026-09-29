import Foundation
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The router's one standing proof of ``RouterTelemetry``'s safety rule: no
/// span attribute, log message, log metadata value or metric dimension carries
/// prompt text, response text, tool arguments, tool output, or embed input
/// text.
///
/// A finished span, a log record and a metric leave the process through
/// whatever backend the host application bootstrapped, and the router cannot
/// know where that backend sends what it receives — so the rule is not
/// advice, it is a contract, and this suite is where the contract is measured
/// rather than merely written down.
///
/// The suite drives work that produces content inside one
/// `TelemetryCapture.run(forbidding:sourceLocation:_:)` of the Extras
/// `TelemetryTestSupport` helper: a scripted answer, a tool call inside it, a
/// compaction over what the answer accumulated, a compaction whose target
/// leaves no room for a summary, so that the session logs the shortfall, an
/// embed, and one more answer
/// whose first tool call the parser rejects, so that the session logs its
/// retry. The capture reads *every* span name and attribute, *every* log
/// message and metadata value and *every* metric label and dimension, and
/// records an issue for any of them that carries the fixture's own content.
/// Nothing here names a record to check, so a card that teaches the router a
/// new span, log record or metric is held to the rule the moment it lands,
/// with no edit to this file.
///
/// Each session gets the logger and the metrics factory of the capture
/// explicitly: the pump of a session is a detached task, and it does not
/// inherit the task-locals of the capture.
@Suite("No span, log record or metric carries the caller's content")
struct TelemetryContentSafetyTests {
    /// The text the embed call embeds — distinctive, so a record carrying it
    /// cannot be carrying anything else.
    private static let embedInput = "embed-input-9c2e"

    /// The `value` argument of the scripted tool call — distinctive for the
    /// same reason.
    private static let toolArgument = "tool-argument-4f7a"

    /// The prompt of the answer whose first tool call the parser rejects.
    private static let rejectedCallPrompt = "rejected-call-prompt-3b1d"

    /// The target fraction of the budget of the shortfall compaction. A
    /// target of zero tokens leaves no room for a summary.
    private static let noRoomTarget = 0.0

    /// The calling suite's name, so a leaked temp directory is attributable.
    private static let tempDirPrefix = "TelemetryContentSafetyTests"

    /// The output text of the scripted tool call.
    private static var toolOutput: String {
        ScriptedToolFixture.marker(for: toolArgument)
    }

    /// The answer the scripted model composes from the one tool output.
    private static var scriptedAnswer: String {
        ScriptedToolFixture.answer(fromToolOutputs: [toolOutput])
    }

    /// Every text that no telemetry record may carry: the prompts, the
    /// answers, the tool arguments, the tool output and the embed input.
    private static var forbiddenContent: [String] {
        [
            ScriptedToolFixture.prompt, scriptedAnswer, toolArgument, toolOutput, embedInput,
            rejectedCallPrompt, RejectingLanguageModel.Executor.answerText,
            RejectingLanguageModel.Executor.rejectedArgumentValue,
        ]
    }

    @Test("no span, log record or metric carries prompt, response, tool or embed-input text")
    func noTelemetryCarriesTheCallersContent() async throws {
        try await TelemetryCapture.run(forbidding: Self.forbiddenContent) { context in
            try await Self.driveScriptedSession(in: context)
            try await Self.driveRejectedCallRetry(in: context)

            // A suite that measured nothing would pass silently, so say what was
            // measured before the capture says it was clean.
            #expect(context.spans.contains { $0.operationName == ExtrasTelemetryNames.toolSpan })
            context.expectLogged(
                containing: RejectedToolCallRetry.retryLogMessage,
                metadata: [
                    RouterTelemetry.LogMetadataKey.toolName: RejectingLanguageModel.Executor.rejectedToolName
                ])
            #expect(
                context.metricRecords.contains { record in
                    record.label == ExtrasTelemetryNames.toolCallsMetric
                        && record.dimensions.contains {
                            $0.key == ExtrasTelemetryNames.toolNameDimension && $0.value == MarkerEmittingTool.toolName
                        }
                })
            #expect(context.metricRecords.contains { $0.label == RouterTelemetry.MetricName.compactionCount })
            context.expectLogged(
                containing: Compactor.shortfallLogMessage,
                metadata: [RouterTelemetry.LogMetadataKey.shortfall: "targetLeavesNoRoomForSummary"])
        }
    }

    /// Drives the scripted session: one answer with one tool call, a
    /// compaction over what the answer accumulated, a compaction with a
    /// shortfall, and one embed.
    ///
    /// - Parameter context: The capture the session reports to.
    /// - Throws: Whatever the session, the compaction or the embed throws.
    private static func driveScriptedSession(in context: TelemetryCapture.Context) async throws {
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1",
                        toolName: MarkerEmittingTool.toolName,
                        argument: .literal(toolArgument))
                ]
            ]),
            mounting: [MarkerEmittingTool()],
            tempDirPrefix: tempDirPrefix,
            tracer: context.tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.session.useCaptureLogger(for: context.logger)
        await fixture.session.useCaptureMetrics(for: context.metricsFactory)

        // One answer, with one tool call inside it. The answer is composed from
        // the tool output the model read back, so it carries the marker only if
        // the output really reached generation.
        let answer = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        #expect(answer == scriptedAnswer)

        // A compaction over what the answer accumulated. The budget is derived from
        // the measured pre-compaction size, and the shrink says the compaction really ran.
        let compaction = try await fixture.session.compact(
            budget: summarizingCompactionBudget(for: fixture.transcriptEntries()))
        #expect(compaction.tokensAfter < compaction.tokensBefore)

        // A compaction whose target is zero tokens: the target leaves no room for
        // a summary, so the compaction has a shortfall, and the session logs it.
        let shortfallCompaction = try await fixture.session.compact(
            budget: TokenBudget(limit: compaction.tokensAfter, target: noRoomTarget))
        #expect(shortfallCompaction.shortfall == .targetLeavesNoRoomForSummary(allowedSummaryTokens: 0))

        // One embed, over the same profile.
        _ = try await fixture.profile.embedding.embed(texts: [embedInput])
    }

    /// Drives one answer whose first tool call the parser rejects, so the
    /// session logs the retry that sends the rejection back to the model.
    ///
    /// - Parameter context: The capture the session reports to.
    /// - Throws: Whatever profile resolution or the answer throws.
    private static func driveRejectedCallRetry(in context: TelemetryCapture.Context) async throws {
        let fixture = try await RejectingSessionFixture.make(
            rejectionCount: 1, tempDirPrefix: tempDirPrefix, tracer: context.tracer)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        await fixture.session.useCaptureLogger(for: context.logger)
        await fixture.session.useCaptureMetrics(for: context.metricsFactory)

        let answer = try await fixture.session.respond(to: rejectedCallPrompt)
        #expect(answer == RejectingLanguageModel.Executor.answerText)
    }
}
