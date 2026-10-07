import Foundation
import InMemoryTracing
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The failure half of the safety rule: a span whose work throws records the
/// error status and the type of the error, and never the description of the
/// error.
///
/// `withSpan` of swift-distributed-tracing records each error that its body
/// throws, and a telemetry backend exports the description of that error. The
/// description of an error can hold the caller's content, for example a path, a
/// part of a prompt or a tool argument. Each test here makes the work of one
/// span throw an error whose description is content, and the capture then
/// finds that content in no span, no log record and no metric.
extension TelemetryContentSafetyTests {
    /// An error whose description is the caller's content, as the description
    /// of a real error can be.
    struct ContentBearingError: Error, CustomStringConvertible {
        /// The content that the error carries.
        let description: String
    }

    /// The content that each failing work carries in its error — distinctive,
    /// so a record that carries it cannot be carrying anything else.
    static let failureContent = "failure-content-8d5e"

    /// The error that each failing work throws.
    static var contentBearingError: ContentBearingError {
        ContentBearingError(description: failureContent)
    }

    /// The model reference of the session spans that the session test opens.
    static let failingSpanModel: ModelRef = "org/failing-session"

    /// The failure types of the finished spans with the name `spanName`, in
    /// the order that they finished.
    ///
    /// - Parameters:
    ///   - spanName: The name of the spans to read.
    ///   - context: The capture that holds the spans.
    /// - Returns: The ``FinishedInMemorySpan/failureType`` of each span.
    static func failureTypes(
        ofSpansNamed spanName: String,
        in context: TelemetryCapture.Context
    ) -> [String?] {
        context.spans.filter { $0.operationName == spanName }.map(\.failureType)
    }

    @Test("a session span whose work throws records the error type and no content")
    func failedSessionSpanRecordsOnlyTheErrorType() async throws {
        try await TelemetryCapture.run(forbidding: [Self.failureContent]) { context in
            #expect(throws: ContentBearingError.self) {
                try withSessionSpan(
                    routerId: ULID(), sessionId: ULID(), parentId: nil, model: Self.failingSpanModel,
                    origin: .new, tracer: context.tracer
                ) { () throws -> Int in throw Self.contentBearingError }
            }
            await #expect(throws: ContentBearingError.self) {
                try await withSessionSpan(
                    routerId: ULID(), sessionId: ULID(), parentId: nil, model: Self.failingSpanModel,
                    origin: .restored, tracer: context.tracer
                ) { () async throws -> Int in throw Self.contentBearingError }
            }

            let expected = "\(ContentBearingError.self)"
            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.session, in: context)
                    == [expected, expected])
        }
    }

    @Test("a compact span whose work throws records the error type and no content")
    func failedCompactSpanRecordsOnlyTheErrorType() async throws {
        try await TelemetryCapture.run(forbidding: [Self.failureContent]) { context in
            let fixture = try await Self.makeFailingSpanFixture(in: context)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let session = try #require(fixture.session as? RoutedSessionActor)

            await #expect(throws: ContentBearingError.self) {
                try await session.withCompactionSpan(trigger: .caller) { throw Self.contentBearingError }
            }

            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.compact, in: context)
                    == ["\(ContentBearingError.self)"])
        }
    }

    @Test("a fork span whose work throws records the error type and no content")
    func failedForkSpanRecordsOnlyTheErrorType() async throws {
        try await TelemetryCapture.run(forbidding: [Self.failureContent]) { context in
            let fixture = try await Self.makeFailingSpanFixture(in: context)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let session = try #require(fixture.session as? RoutedSessionActor)

            await #expect(throws: ContentBearingError.self) {
                try await session.withForkSpan { throw Self.contentBearingError }
            }

            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.fork, in: context)
                    == ["\(ContentBearingError.self)"])
        }
    }

    @Test("a submission span whose attempt throws records the error type and no content")
    func failedSubmissionSpanRecordsOnlyTheErrorType() async throws {
        try await TelemetryCapture.run(forbidding: [Self.failureContent]) { context in
            let fixture = try await Self.makeFailingSpanFixture(in: context)
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let session = try #require(fixture.session as? RoutedSessionActor)

            // The answer pump does these three steps for an attempt that
            // throws: it opens the submission, records the error of the
            // attempt, and ends the submission.
            await session.beginSubmission(cause: .message, messageIds: [])
            await session.recordSubmissionError(Self.contentBearingError)
            await session.endSubmission(usage: nil, finishReason: .completed, measuredRender: nil, onEvent: nil)

            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.submission, in: context)
                    == ["\(ContentBearingError.self)"])
        }
    }

    @Test("an embed span whose container throws records the error type and no content")
    func failedEmbedSpanRecordsOnlyTheErrorType() async throws {
        try await TelemetryCapture.run(forbidding: [Self.failureContent]) { context in
            let embedder = HandBuiltProfileFixtures.makeEmbedder(
                chosen: Self.failingSpanModel,
                container: ThrowingEmbeddingContainer(failure: Self.contentBearingError),
                routerId: ULID(),
                tracer: context.tracer
            )

            await #expect(throws: ContentBearingError.self) {
                _ = try await embedder.embed(texts: [Self.failureContent])
            }

            #expect(
                Self.failureTypes(ofSpansNamed: RouterTelemetry.SpanName.embed, in: context)
                    == ["\(ContentBearingError.self)"])
        }
    }

    /// Makes a scripted session that reports to `context`, for a test that
    /// drives a span of the session directly.
    ///
    /// - Parameter context: The capture that the session reports to.
    /// - Returns: The fixture. The caller removes its directory.
    /// - Throws: Whatever profile resolution throws.
    private static func makeFailingSpanFixture(
        in context: TelemetryCapture.Context
    ) async throws -> ScriptedSessionFixture {
        try await ScriptedSessionFixture.make(
            playing: ScriptedAnswerScript(rounds: []),
            mounting: [],
            tempDirPrefix: tempDirPrefix,
            tracer: context.tracer)
    }
}
