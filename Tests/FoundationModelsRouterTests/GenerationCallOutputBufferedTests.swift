import Foundation
import FoundationModels
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Task ^kg3yjc9: a pass whose output reaches the session as exactly one
/// output event is buffered. Its first token cannot be seen, so its call is
/// marked buffered (``GenerationCallUsage/outputBuffered``) and has no time to
/// first token by design. A streamed pass is not buffered and has that time.
/// A pass with no output event is not buffered either.
///
/// The ledger tests apply the phases of one pass by hand. The session tests
/// drive a real `LanguageModelSession` over a ``MeteredToolLoopLanguageModel``
/// and read the mark back live, from the run journal and from an
/// `InMemoryTracer`.
@Suite("Generation call output buffered: a pass whose output arrives in one event")
struct GenerationCallOutputBufferedTests {
    /// The prefix of each temp directory this suite makes.
    private static let tempDirPrefix = "GenerationCallOutputBufferedTests"

    /// The working context of the metered session.
    private static let contextTokens = 1_000

    /// The prompt of every answer. The metered model never reads it.
    private static let prompt = "look a thing up, then tell me what you found"

    /// The prefill and the decode wait of each paced call.
    private static let wait = Duration.milliseconds(20)

    /// The time from the start of a pass to its first output event in the
    /// ledger tests.
    private static let prefill = Duration.milliseconds(40)

    /// The time from the first output of a pass to its end in the ledger
    /// tests.
    private static let decode = Duration.milliseconds(60)

    /// The scripted calls of the session tests: a tool call that sends its
    /// whole output in one event at its end, as the allowed-tool path of the
    /// MLX executor does, and an answer that streams.
    private static let calls = [
        MeteredGenerationCall(
            tokensIn: 100, tokensOut: 30,
            pacing: MeteredCallPacing(prefill: wait, decode: wait, firstOutput: .nothingUntilTheEnd)),
        MeteredGenerationCall(
            tokensIn: 200, tokensOut: 50,
            pacing: MeteredCallPacing(prefill: wait, decode: wait, firstOutput: .responseText)),
    ]

    /// The timing of a call whose pass gave `phases` after its start.
    ///
    /// - Parameter phases: The phases of the pass after its start, given the
    ///   instant at which the pass started.
    /// - Returns: The timing of the call, ended ``prefill`` plus ``decode``
    ///   after the start.
    private static func timing(
        of phases: (ContinuousClock.Instant) -> [GenerationCallPhase]
    ) -> GenerationCallTiming {
        let startedAt = ContinuousClock.now
        var ledger = GenerationCallLedger(usageBefore: (input: 0, output: 0), responseTokenCeiling: nil)
        ledger.apply(.passStarted(at: startedAt))
        for phase in phases(startedAt) {
            ledger.apply(phase)
        }
        return ledger.timingOfEndedCall(endedAt: startedAt + prefill + decode)
    }

    @Test("a pass with one output event is buffered, with no time to first token")
    func oneOutputEventIsBuffered() {
        let timing = Self.timing { _ in [.firstOutputEvent] }

        #expect(timing.outputBuffered)
        #expect(timing.timeToFirstToken == nil)
        #expect(timing.decodeTime == nil)
    }

    @Test("a streamed pass is not buffered, and has its time to first token")
    func streamedPassIsNotBuffered() {
        let timing = Self.timing { startedAt in
            [.firstOutputEvent, .firstOutput(at: startedAt + Self.prefill)]
        }

        #expect(!timing.outputBuffered)
        #expect(timing.timeToFirstToken == Self.prefill)
        #expect(timing.decodeTime == Self.decode)
    }

    @Test("a pass with no output event is not buffered")
    func passWithoutOutputIsNotBuffered() {
        let timing = Self.timing { _ in [] }

        #expect(!timing.outputBuffered)
        #expect(timing.timeToFirstToken == nil)
    }

    @Test("the start of the next pass clears the mark of the last one")
    func nextPassStartClearsTheMark() {
        let timing = Self.timing { startedAt in [.firstOutputEvent, .passStarted(at: startedAt)] }

        #expect(!timing.outputBuffered)
    }

    @Test("a call whose output arrives in one event is marked buffered live; a streamed call is not")
    func liveUsageMarksTheBufferedCall() async throws {
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: Self.calls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix)
        defer { await fixture.end() }

        let usages = try await collect(fixture.session.streamEvents(to: Self.prompt, maxTokens: nil)).generationCalls

        #expect(usages.map(\.outputBuffered) == [true, false])
        #expect(usages.map(\.firstTokenSeen) == [false, true])
    }

    @Test("the journal row and the span of each call carry whether its output was buffered")
    func journalAndSpanMarkTheBufferedCall() async throws {
        let tracer = InMemoryTracer()
        let fixture = try await MeteredToolLoopSessionFixture.make(
            calls: Self.calls, context: Self.contextTokens, tempDirPrefix: Self.tempDirPrefix, tracer: tracer)
        defer { await fixture.end() }

        _ = try await collect(fixture.session.streamEvents(to: Self.prompt, maxTokens: nil))

        let records = await fixture.recorder.events.filter { $0.kind == .generationCall }
        #expect(records.map(\.outputBuffered) == [true, false])
        let otherEvents = await fixture.recorder.events.filter { $0.kind != .generationCall }
        #expect(otherEvents.allSatisfy { $0.outputBuffered == nil })
        let spans = tracer.finishedSpans.filter { $0.operationName == RouterTelemetry.SpanName.generationCall }
        #expect(
            spans.map { $0.attributes.get(RouterTelemetry.AttributeKey.outputBuffered) } == [.bool(true), .bool(false)])
    }
}
