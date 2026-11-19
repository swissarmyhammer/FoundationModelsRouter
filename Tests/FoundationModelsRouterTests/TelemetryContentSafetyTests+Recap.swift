import Foundation
import FoundationModelsExtras
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The recap span of D206 under the safety rule: a recap call whose flash
/// model throws records the error type, and no span, log record or metric
/// carries the user prompt, the reply or the tool target of the turn, or the
/// content of the error.
extension TelemetryContentSafetyTests {
    /// The user prompt of the turn of the recap test.
    private static let recapPromptContent = "recap-prompt-6a1c"

    /// The final reply of the turn of the recap test.
    private static let recapReplyContent = "recap-reply-2e9b"

    /// The path that the tool call of the turn of the recap test names.
    private static let recapToolTarget = "recap-target-7d3f"

    @Test("a recap span whose flash model throws records the error type and no content")
    func failedRecapSpanRecordsOnlyTheErrorType() async throws {
        let forbidden = [Self.failureContent, Self.recapPromptContent, Self.recapReplyContent, Self.recapToolTarget]
        try await TelemetryCapture.run(forbidding: forbidden) { context in
            let clock = ManualRunClock()
            let recapper = SessionRecapper(clock: clock)
            let host = FakeRecapHost(output: "", changes: recapper.jobChanges, spanTracer: context.tracer)
            host.backend.failEachCall(throwing: Self.contentBearingError)
            recapper.use(host: host.host)
            let fixture = SessionRecapperTests.Fixture(
                clock: clock, recapper: recapper, host: host, session: ULID.generate())
            host.admit(fixture.session)
            let toolCall = ToolCallEntry(
                id: "call-1", name: "edit", argumentsJSON: #"{"path":"\#(Self.recapToolTarget)"}"#,
                status: .completed, summary: nil)
            fixture.runTurn(prompt: Self.recapPromptContent, reply: Self.recapReplyContent, toolCalls: [toolCall])

            try await fixture.passTheIdleTime()

            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.recap, in: context)
                    == ["\(ContentBearingError.self)"])
        }
    }
}
