import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Task ^rw72f4j: while an operation of the session is pending, a tool call
/// that the host check marks as a no-op does not run, gets no answer, and does
/// not go into the context. A round of only no-op calls stops the generation,
/// and the injected result of the pending operation is the next message that
/// starts the model. A real call always runs, also in the same round as a
/// no-op call, and with no pending operation a no-op call runs as before.
/// Task ^4nk083c: a restored session gets the check from the restore call.
///
/// Each test drives the production backend and a real `LanguageModelSession`
/// over a ``NoOpToolCallModel``. No GPU is in the loop. A ``RunLatch`` holds
/// the background job, and each wait reads a state until it holds.
@Suite("A no-op tool call stops the generation while an operation is pending", .timeLimit(.minutes(1)))
struct NoOpToolCallStopTests {
    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "NoOpToolCallStopTests"

    /// The prompt of the caller message of every test.
    private static let prompt = "do the work"

    /// The snippet of a real `runCode` call: the host check does not mark it.
    private static let realCode = "tools.search()"

    /// The model calls of an answer that starts the job and then calls
    /// `runCode`: the first call, and the call after the pending envelope.
    private static let callsBeforeTheResult = 2

    /// The `runCode` calls of `transcript`, in order.
    private static func runCodeCalls(_ transcript: Transcript) -> [Transcript.ToolCall] {
        transcript.flatMap { entry -> [Transcript.ToolCall] in
            guard case .toolCalls(let calls) = entry else { return [] }
            return calls.filter { $0.toolName == CountingRunCodeTool.toolName }
        }
    }

    /// Whether `transcript` holds a call of `runCode`.
    private static func holdsRunCodeCall(_ transcript: Transcript) -> Bool {
        !runCodeCalls(transcript).isEmpty
    }

    /// The snippet of `call`, or `nil` when its arguments hold none.
    private static func snippet(of call: Transcript.ToolCall) -> String? {
        try? call.arguments.value(String.self, forProperty: "code")
    }

    /// The `.toolOutput` entries of `transcript` that answer one of `calls`.
    private static func outputs(
        answering calls: [Transcript.ToolCall], in transcript: Transcript
    ) -> [Transcript.ToolOutput] {
        let ids = Set(calls.map(\.id))
        return transcript.compactMap { entry in
            guard case .toolOutput(let output) = entry, ids.contains(output.id) else { return nil }
            return output
        }
    }

    /// Waits, bounded, until the model received `count` calls.
    ///
    /// - Parameters:
    ///   - count: How many calls to wait for.
    ///   - log: The log that the model writes.
    /// - Returns: `true` when the calls arrived inside the bound.
    private static func callsArrive(_ count: Int, in log: RenderProbeLog) async -> Bool {
        await BoundedWait.conditionReached("\(count) model calls") { log.renders.count >= count }
    }

    @Test("pending job and a no-op call: the generation stops, the call is not in the context, and the result is next")
    func aNoOpCallStopsTheGenerationWhileAJobIsPending() async throws {
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: true, codes: [NoOpToolCallSessionFixture.noOpCode], tempDirPrefix: Self.tempDirPrefix)

        _ = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.runs.value == 0)
        #expect(fixture.log.renders.count == Self.callsBeforeTheResult)
        #expect(!Self.holdsRunCodeCall(await fixture.session.transcript))

        await fixture.gate.open()
        #expect(await Self.callsArrive(Self.callsBeforeTheResult + 1, in: fixture.log))
        #expect(await BoundedWait.pumpStops(on: fixture.session))
        let next = try #require(fixture.log.renders.last)
        let nextPrompt = try #require(next.promptTexts.last)
        #expect(nextPrompt.contains(NoOpToolCallSessionFixture.jobOutput))
        #expect(nextPrompt.hasSuffix(RoutedSessionActor.settledRunDeliveryPrompt))
        #expect(!Self.holdsRunCodeCall(next))
        #expect(fixture.runs.value == 0)
        await fixture.end()
    }

    @Test("pending job and a real call: the call runs")
    func aRealCallRunsWhileAJobIsPending() async throws {
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: true, codes: [Self.realCode], tempDirPrefix: Self.tempDirPrefix)

        let answer = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.runs.value == 1)
        #expect(answer == NoOpToolCallModel.Executor.answerText)
        #expect(Self.holdsRunCodeCall(await fixture.session.transcript))
        await fixture.end()
    }

    @Test("pending job and one round of a no-op call and a real call: the real call runs, its result is in the context, and the no-op call is not")
    func aRealCallInTheRoundOfANoOpCallRuns() async throws {
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: true, codes: [NoOpToolCallSessionFixture.noOpCode, Self.realCode],
            tempDirPrefix: Self.tempDirPrefix)

        let answer = try await fixture.session.respond(to: Self.prompt)

        let transcript = await fixture.session.transcript
        let calls = Self.runCodeCalls(transcript)
        #expect(fixture.runs.value == 1)
        #expect(answer == NoOpToolCallModel.Executor.answerText)
        #expect(calls.compactMap(Self.snippet(of:)) == [Self.realCode])
        #expect(Self.outputs(answering: calls, in: transcript).count == calls.count)
        let lastRender = try #require(fixture.log.renders.last)
        #expect(Self.runCodeCalls(lastRender).compactMap(Self.snippet(of:)) == [Self.realCode])
        await fixture.end()
    }

    @Test("a fork keeps the no-op check of its parent")
    func aForkKeepsTheCheck() async throws {
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: false, codes: [NoOpToolCallSessionFixture.noOpCode], tempDirPrefix: Self.tempDirPrefix)
        let noOpArguments = GeneratedContent(properties: ["code": NoOpToolCallSessionFixture.noOpCode])

        let child = try #require(try await fixture.session.fork(workingDirectory: nil) as? RoutedSessionActor)

        #expect(child.isNoOpToolCall(CountingRunCodeTool.toolName, noOpArguments))
        await child.close()
        await fixture.end()
    }

    @Test("a session restored with the check stops at a no-op call while a job is pending")
    func aRestoredSessionWithTheCheckStopsAtANoOpCall() async throws {
        let fixture = try await NoOpToolCallSessionFixture.makeRestored(
            startsJob: true, codes: [NoOpToolCallSessionFixture.noOpCode],
            restoreCheck: NoOpToolCallSessionFixture.isNoOp(toolName:arguments:), tempDirPrefix: Self.tempDirPrefix)

        _ = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.runs.value == 0)
        #expect(fixture.log.renders.count == Self.callsBeforeTheResult)
        #expect(!Self.holdsRunCodeCall(await fixture.session.transcript))
        await fixture.end()
    }

    @Test("a session restored with no check runs a no-op call while a job is pending, as before")
    func aRestoredSessionWithNoCheckRunsANoOpCall() async throws {
        let fixture = try await NoOpToolCallSessionFixture.makeRestored(
            startsJob: true, codes: [NoOpToolCallSessionFixture.noOpCode], restoreCheck: nil,
            tempDirPrefix: Self.tempDirPrefix)

        let answer = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.runs.value == 1)
        #expect(answer == NoOpToolCallModel.Executor.answerText)
        #expect(Self.holdsRunCodeCall(await fixture.session.transcript))
        await fixture.end()
    }

    @Test("no pending operation and a no-op call: the call runs as before")
    func aNoOpCallRunsWithNoPendingOperation() async throws {
        let fixture = try await NoOpToolCallSessionFixture.make(
            startsJob: false, codes: [NoOpToolCallSessionFixture.noOpCode], tempDirPrefix: Self.tempDirPrefix)

        let answer = try await fixture.session.respond(to: Self.prompt)

        #expect(fixture.runs.value == 1)
        #expect(answer == NoOpToolCallModel.Executor.answerText)
        #expect(Self.holdsRunCodeCall(await fixture.session.transcript))
        await fixture.end()
    }
}
