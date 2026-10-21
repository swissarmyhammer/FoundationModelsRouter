import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Task ^0m997jr: the first token of a generation call comes from the first
/// streamed output of any kind, tool-call arguments included, and every call
/// reports its whole time and whether the session saw its first token, so a
/// missing split never reads as zero.
///
/// The suite drives a real `LanguageModelSession` over a
/// ``MeteredToolLoopLanguageModel`` and reads the usage back live, from the
/// run journal and from an `InMemoryTracer`.
@Suite("Generation call first token: any streamed output, and a mark when none was seen")
struct GenerationCallFirstTokenTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "GenerationCallFirstTokenTests"

    /// The working context of the metered session.
    private static let contextTokens = 1_000

    /// The prompt of every answer. The metered model never reads it.
    private static let prompt = "look things up, then tell me what you found"

    /// The prefill and the decode of a paced call: a prefill shorter than the
    /// decode, so a time that puts the two together breaks one of the bounds.
    private static let prefill = Duration.milliseconds(100)

    /// The decode wait of a paced call.
    private static let decode = Duration.milliseconds(300)

    /// The least decode time a paced call may report: half of ``decode``. The
    /// session reads the first token a moment after the call sends it.
    private static let leastDecodeTime = Duration.milliseconds(150)

    /// The pace of a call whose first output is `firstOutput`.
    ///
    /// - Parameter firstOutput: What the call sends first.
    /// - Returns: The pace.
    private static func pacing(_ firstOutput: MeteredFirstOutput) -> MeteredCallPacing {
        MeteredCallPacing(prefill: prefill, decode: decode, firstOutput: firstOutput)
    }

    /// The ``SessionEvent/generationCall(_:)`` payloads of `events`, in order.
    ///
    /// - Parameter events: The events of the answer.
    /// - Returns: The usage of each reported call.
    private static func generationCalls(in events: [SessionEvent]) -> [GenerationCallUsage] {
        events.compactMap { event in
            guard case .generationCall(let usage) = event else { return nil }
            return usage
        }
    }

    /// Drives one answer over `calls` and returns the usage of each call.
    ///
    /// - Parameters:
    ///   - fixture: The session to drive.
    /// - Returns: The usage of each generation call, in call order.
    /// - Throws: Whatever the answer throws.
    private static func driveAnswer(on fixture: MeteredToolLoopSessionFixture) async throws -> [GenerationCallUsage] {
        var events: [SessionEvent] = []
        for try await event in await fixture.session.streamEvents(to: prompt, maxTokens: nil) {
            events.append(event)
        }
        return generationCalls(in: events)
    }

    @Test("a tool-call-only call that streams its arguments records its time to first token and its decode time")
    func streamedToolCallArgumentsGiveTheFirstToken() async throws {
        let calls = [
            MeteredGenerationCall(tokensIn: 100, tokensOut: 30, pacing: Self.pacing(.toolCallArguments)),
            MeteredGenerationCall(tokensIn: 200, tokensOut: 50, pacing: Self.pacing(.responseText)),
        ]
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }

        let usages = try await Self.driveAnswer(on: fixture)

        let toolCall = try #require(usages.first)
        #expect(toolCall.entryKind == .toolCall)
        let timeToFirstToken = try #require(toolCall.timeToFirstToken)
        let decodeTime = try #require(toolCall.decodeTime)
        #expect(timeToFirstToken >= Self.prefill)
        #expect(decodeTime >= Self.leastDecodeTime)
        #expect(toolCall.firstTokenSeen)
    }

    @Test("each call reports its whole call time and whether its first token was seen, live and in the run journal")
    func eachCallReportsItsCallTime() async throws {
        let calls = [
            MeteredGenerationCall(tokensIn: 100, tokensOut: 30, pacing: Self.pacing(.responseText)),
            MeteredGenerationCall(tokensIn: 200, tokensOut: 50, pacing: Self.pacing(.responseText)),
        ]
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }

        let usages = try await Self.driveAnswer(on: fixture)

        #expect(usages.count == calls.count)
        for usage in usages {
            let callDuration = try #require(usage.callDuration)
            #expect(callDuration >= Self.prefill + Self.leastDecodeTime)
            #expect(usage.firstTokenSeen == (usage.timeToFirstToken != nil))
        }
        let records = await fixture.recorder.events.filter { $0.kind == .generationCall }
        #expect(records.map(\.callMs) == usages.map { $0.callDuration?.wholeMilliseconds })
        #expect(records.map(\.firstTokenSeen) == usages.map(\.firstTokenSeen))
        let otherEvents = await fixture.recorder.events.filter { $0.kind != .generationCall }
        #expect(otherEvents.allSatisfy { $0.callMs == nil && $0.firstTokenSeen == nil })
    }

    @Test("a call whose first token was not seen is marked so on its span and its journal row, with its call time")
    func unseenFirstTokenIsMarked() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: [MeteredGenerationCall(tokensIn: 100, tokensOut: 30)], context: Self.contextTokens,
            tempDirPrefix: Self.tempDirPrefix, tracer: tracer)
        defer { await fixture.end() }
        let session = try #require(fixture.session as? RoutedSessionActor)
        let callDuration = Duration.milliseconds(8_400)
        let usage = GenerationCallUsage(
            tokensIn: 100, tokensOut: 326, finishReason: .completed, entryKind: .toolCall, contextFill: 0.4,
            callDuration: callDuration)

        await session.beginSubmission(cause: .message, mailIds: [])
        await session.traceGenerationCall(usage, duration: callDuration, toolCallCount: 1)
        await session.endSubmission(usage: nil, finishReason: .completed, onEvent: nil)
        await session.report(generationCall: usage)

        #expect(!usage.firstTokenSeen)
        let span = try #require(tracer.finishedSpans.first { $0.operationName == RouterTelemetry.SpanName.generationCall })
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.firstTokenSeen) == .bool(false))
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.callMs) == .int64(Int64(callDuration.wholeMilliseconds)))
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.timeToFirstTokenMs) == nil)
        #expect(span.attributes.get(RouterTelemetry.AttributeKey.decodeMs) == nil)
        let record = try #require(await fixture.recorder.events.last { $0.kind == .generationCall })
        #expect(record.firstTokenSeen == false)
        #expect(record.callMs == callDuration.wholeMilliseconds)
        #expect(record.timeToFirstTokenMs == nil)
    }

    @Test("a call whose first token was seen is marked so on its span")
    func seenFirstTokenIsMarkedOnTheSpan() async throws {
        let tracer = InMemoryTracer()
        let calls = [
            MeteredGenerationCall(tokensIn: 100, tokensOut: 30, pacing: Self.pacing(.responseText)),
            MeteredGenerationCall(tokensIn: 200, tokensOut: 50, pacing: Self.pacing(.responseText)),
        ]
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: calls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix, tracer: tracer)
        defer { await fixture.end() }

        _ = try await Self.driveAnswer(on: fixture)

        let spans = tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.generationCall }
        #expect(spans.count == calls.count)
        #expect(spans.allSatisfy { $0.attributes.get(RouterTelemetry.AttributeKey.firstTokenSeen) == .bool(true) })
        #expect(
            spans.allSatisfy { span in
                guard case .int64(let callMs) = span.attributes.get(RouterTelemetry.AttributeKey.callMs) else {
                    return false
                }
                return callMs >= Int64((Self.prefill + Self.leastDecodeTime).wholeMilliseconds)
            })
    }
}
