import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing

@testable import FoundationModelsRouter

/// The recap maker of a session directory (D206), over a fake host and a fake
/// flash model, on a manual clock: no sleep and no real time.
///
/// A test gives the recapper the events of a turn as the directory gives
/// them, moves the clock, and waits on the signal of the jobs of the
/// recapper until the job of the session ended.
@Suite("SessionRecapper: the recap of a session after a turn that is not trivial")
struct SessionRecapperTests {
    /// The parts of one test.
    struct Fixture {
        /// The clock of the recapper.
        let clock: ManualRunClock

        /// The recapper under test.
        let recapper: SessionRecapper

        /// The host of the recapper, with the fake flash model.
        let host: FakeRecapHost

        /// The session of the turns.
        let session: ULID

        /// Gives the recapper the events of one turn of ``session``: its
        /// start, its delivered prompt, its answer and its end with the state
        /// idle.
        ///
        /// - Parameters:
        ///   - prompt: The user prompt of the turn.
        ///   - reply: The final reply of the turn.
        ///   - toolCalls: The tool calls of the turn.
        ///   - getsRecap: Whether the directory gives the session a recap.
        func runTurn(prompt: String, reply: String, toolCalls: [ToolCallEntry] = [], getsRecap: Bool = true) {
            startTurn()
            let mail = MailID()
            recapper.noteDelivered([DeliveredPrompt(mail: mail, text: prompt)], of: session)
            recapper.observe(
                .answered(
                    SessionAnswer(
                        reply: reply, mailIds: [mail], usage: nil, compactions: [], toolCalls: toolCalls,
                        toolInvocations: [])),
                of: session, isIdle: false, getsRecap: true)
            recapper.observe(.workEnded, of: session, isIdle: true, getsRecap: getsRecap)
        }

        /// Gives the recapper the start of a turn of ``session``.
        func startTurn() {
            recapper.observe(.workStarted, of: session, isIdle: false, getsRecap: true)
        }

        /// Waits until no job of the recapper waits, queues or runs.
        ///
        /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
        func waitForTheEndOfTheJobs() async throws {
            try await recapper.jobChanges.wait(until: { recapper.jobCount == 0 })
        }

        /// Moves the clock past the idle time and waits for the end of the
        /// job.
        ///
        /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
        func passTheIdleTime() async throws {
            clock.advance(by: SessionRecapper.idleTime)
            try await waitForTheEndOfTheJobs()
        }
    }

    // MARK: - Constants

    /// The prompt of the first turn.
    private static let firstPrompt = "fix the failing parser test"

    /// The prompt of the second turn.
    private static let secondPrompt = "now update the change log"

    /// The reply of a turn with a tool call.
    private static let reply = "I fixed the test."

    /// A reply of 20 characters.
    private static let shortReply = "Hello! How are you?!"

    /// The output of the fake flash model.
    private static let recap = "Fixed the failing parser test; the tests pass now."

    /// The tool call of a turn that is not trivial.
    private static let toolCall = ToolCallEntry(
        id: "call-1", name: "edit", argumentsJSON: #"{"path":"Sources/Parser.swift"}"#, status: .completed,
        summary: nil)

    /// The time of a new turn after the end of the first turn: less than the
    /// idle time.
    private static let earlyTurn: Duration = .seconds(5)

    /// The length of the output of the test of a long output.
    private static let longOutputLength = 400

    // MARK: - Helpers

    /// Makes a fixture whose session gets a recap.
    ///
    /// - Parameters:
    ///   - output: The text each recap call answers.
    ///   - isHeld: `true` to hold each recap call until the test releases it
    ///     or its task is cancelled.
    ///   - holdsWrites: `true` to stop each write at the gate of the host
    ///     until the test opens it.
    /// - Returns: The fixture.
    private static func makeFixture(output: String = recap, isHeld: Bool = false, holdsWrites: Bool = false)
        -> Fixture
    {
        let clock = ManualRunClock()
        let recapper = SessionRecapper(clock: clock)
        let host = FakeRecapHost(
            output: output, isHeld: isHeld, changes: recapper.jobChanges, holdsWrites: holdsWrites)
        recapper.use(host: host.host)
        let session = ULID.generate()
        host.admit(session)
        return Fixture(clock: clock, recapper: recapper, host: host, session: session)
    }

    // MARK: - The wait and the call

    /// The production change that makes this test fail: a recapper that
    /// makes no call after the idle time.
    @Test("a turn with a tool call and the idle time make one recap call")
    func aTurnWithAToolCallMakesOneRecapCall() async throws {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        #expect(fixture.host.backend.calls.count == 1)
    }

    /// The production change that makes this test fail: a recapper that
    /// writes no recap after its call.
    @Test("the recap of the call goes to the record of the session")
    func theRecapGoesToTheRecordOfTheSession() async throws {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        #expect(fixture.host.writes == [FakeRecapHost.Write(recap: Self.recap, id: fixture.session)])
    }

    /// The production change that makes this test fail: a call before the
    /// idle time.
    @Test("no call comes before the idle time")
    func noCallComesBeforeTheIdleTime() {
        let fixture = Self.makeFixture()

        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        #expect(fixture.recapper.jobCount == 1 && fixture.host.backend.calls.isEmpty)
    }

    /// The production change that makes this test fail: a call with the
    /// reasoning on or with no token ceiling.
    @Test("the recap call asks for at most 80 tokens with the reasoning off")
    func theRecapCallAsksForAtMost80TokensWithTheReasoningOff() async throws {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        let call = try #require(fixture.host.backend.calls.first)
        #expect(call.maxTokens == SessionRecapper.outputTokenLimit && call.reasoningOff)
    }

    /// The production change that makes this test fail: an input with no
    /// tool call line.
    @Test("the input of the call names the tool call and its path")
    func theInputNamesTheToolCallAndItsPath() async throws {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        let call = try #require(fixture.host.backend.calls.first)
        #expect(call.prompt.contains("edit Sources/Parser.swift"))
    }

    // MARK: - The trivial turn

    /// The production change that makes this test fail: a recapper that
    /// waits after each turn.
    @Test("a turn with no tool call and a reply of 20 characters starts no wait")
    func aTrivialTurnStartsNoWait() {
        let fixture = Self.makeFixture()

        fixture.runTurn(prompt: "hi", reply: Self.shortReply)

        #expect(fixture.recapper.jobCount == 0)
    }

    /// The production change that makes this test fail: a trivial rule that
    /// looks only at the tool calls.
    @Test("a turn with a reply of 280 characters is not trivial")
    func aTurnWithALongReplyIsNotTrivial() {
        let fixture = Self.makeFixture()

        fixture.runTurn(
            prompt: Self.firstPrompt, reply: String(repeating: "r", count: SessionRecapper.trivialReplyLength))

        #expect(fixture.recapper.jobCount == 1)
    }

    /// The production change that makes this test fail: a turn that ended
    /// with a cancel and still counts.
    @Test("a turn that ended with a cancel starts no wait")
    func aCancelledTurnStartsNoWait() {
        let fixture = Self.makeFixture()
        fixture.startTurn()
        fixture.recapper.observe(
            .answerFailed(AnswerFailure(mailIds: [], reason: .cancelled)), of: fixture.session, isIdle: false,
            getsRecap: true)

        fixture.recapper.observe(.workEnded, of: fixture.session, isIdle: true, getsRecap: true)

        #expect(fixture.recapper.jobCount == 0)
    }

    /// The production change that makes this test fail: a recap of a turn
    /// that ends with an open question.
    @Test("a turn that ends with the state needsInput starts no wait")
    func aTurnThatEndsWithAnOpenQuestionStartsNoWait() {
        let fixture = Self.makeFixture()
        fixture.startTurn()
        fixture.recapper.observe(
            .answered(
                SessionAnswer(
                    reply: Self.reply, mailIds: [], usage: nil, compactions: [], toolCalls: [Self.toolCall],
                    toolInvocations: [])),
            of: fixture.session, isIdle: false, getsRecap: true)

        fixture.recapper.observe(.workEnded, of: fixture.session, isIdle: false, getsRecap: true)

        #expect(fixture.recapper.jobCount == 0)
    }

    // MARK: - A new turn, an archive and the host

    /// The production change that makes this test fail: a new turn that does
    /// not cancel the wait, or a recap that keeps only the last turn.
    @Test("a new turn cancels the wait, and the next recap has the prompts of both turns")
    func aNewTurnCancelsTheWaitAndTheRecapHasBothPrompts() async throws {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])
        fixture.clock.advance(by: Self.earlyTurn)
        fixture.runTurn(prompt: Self.secondPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        let prompts = fixture.host.backend.calls.map(\.prompt)
        #expect(
            prompts.count == 1
                && prompts.allSatisfy { $0.contains(Self.firstPrompt) && $0.contains(Self.secondPrompt) })
    }

    /// The production change that makes this test fail: a new turn that
    /// leaves the wait of the earlier turn.
    @Test("the start of a new turn cancels the wait")
    func theStartOfANewTurnCancelsTheWait() {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        fixture.startTurn()

        #expect(fixture.recapper.jobCount == 0)
    }

    /// The production change that makes this test fail: an archive that
    /// leaves the wait of the session.
    @Test("an archive during the wait cancels the wait")
    func anArchiveCancelsTheWait() {
        let fixture = Self.makeFixture()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        fixture.recapper.forget(fixture.session)

        #expect(fixture.recapper.jobCount == 0)
    }

    /// The production change that makes this test fail: a wait for a session
    /// that gets no recap: a subagent, a session of a folder whose policy is
    /// off, or a session that is not live.
    @Test("a session that gets no recap starts no wait")
    func aSessionWithNoRecapStartsNoWait() {
        let fixture = Self.makeFixture()

        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall], getsRecap: false)

        #expect(fixture.recapper.jobCount == 0)
    }

    /// The production change that makes this test fail: a call for a
    /// session that the host gives no recap when the wait ends: for example a
    /// session whose folder turned the recap policy off during the wait.
    @Test("a session that the host gives no recap at the end of the wait gets no call")
    func aSessionWithNoTargetGetsNoCall() async throws {
        let fixture = Self.makeFixture()
        let other = Fixture(
            clock: fixture.clock, recapper: fixture.recapper, host: fixture.host, session: ULID.generate())
        other.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await other.passTheIdleTime()

        #expect(fixture.host.backend.calls.isEmpty)
    }

    // MARK: - The output and the failure

    /// The production change that makes this test fail: a write of the whole
    /// output of the model.
    @Test("an output of 400 characters gives a recap of at most 200 characters")
    func aLongOutputGivesAShortRecap() async throws {
        let output = String(repeating: "Fixed it and ", count: Self.longOutputLength / "Fixed it and ".count + 1)
        let fixture = Self.makeFixture(output: output)
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        let write = try #require(fixture.host.writes.first)
        #expect(write.recap.count <= SessionRecapOutput.characterLimit && output.hasPrefix(write.recap + " "))
    }

    /// The production change that makes this test fail: a failure of the
    /// model that writes a recap.
    @Test("a model error writes no recap")
    func aModelErrorWritesNoRecap() async throws {
        let fixture = Self.makeFixture()
        fixture.host.backend.failEachCall()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        #expect(fixture.host.writes.isEmpty)
    }

    /// The production change that makes this test fail: a failure of the
    /// model that leaves no span.
    @Test("a model error writes a recap span with the error, the session and the slot")
    func aModelErrorWritesASpan() async throws {
        let fixture = Self.makeFixture()
        fixture.host.backend.failEachCall()
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])

        try await fixture.passTheIdleTime()

        let span = try #require(fixture.host.tracer.finishedSpans(named: RouterTelemetry.SpanName.recap).first)
        #expect(
            span.attributes.get(RouterTelemetry.AttributeKey.errorType)
                == .string("\(RecapProbeBackend.Failure.self)")
                && span.attributes.get(RouterTelemetry.AttributeKey.sessionId)
                    == .string(fixture.session.description)
                && span.attributes.get(RouterTelemetry.AttributeKey.slot) == .string(ModelSlot.flash.rawValue)
                && span.attributes.get(RouterTelemetry.AttributeKey.tokensIn) != nil)
    }

    // MARK: - The flash model and the new turn during the call

    /// The production change that makes this test fail: a call that starts
    /// while a turn of another session runs on the flash model.
    @Test("the call waits until no turn runs on the flash model")
    func theCallWaitsUntilNoTurnRunsOnTheFlashModel() async throws {
        let fixture = Self.makeFixture()
        fixture.host.setBusy(true)
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])
        fixture.clock.advance(by: SessionRecapper.idleTime)
        try await fixture.recapper.jobChanges.wait(
            until: { fixture.host.busyChecks >= 1 }, endingOn: { fixture.recapper.jobCount == 0 })
        let callsWhileBusy = fixture.host.backend.calls.count
        fixture.host.setBusy(false)

        fixture.recapper.observe(.workEnded, of: ULID.generate(), isIdle: true, getsRecap: true)
        try await fixture.waitForTheEndOfTheJobs()

        #expect(callsWhileBusy == 0 && fixture.host.backend.calls.count == 1)
    }

    /// The production change that makes this test fail: a new turn that does
    /// not cancel the running call, so its output is written.
    ///
    /// The test releases the held call after the new turn: a call that the
    /// turn did not cancel then answers, and the recapper writes its output.
    @Test("a new turn of the session during the call cancels the call and writes nothing")
    func aNewTurnDuringTheCallCancelsTheCall() async throws {
        let fixture = Self.makeFixture(isHeld: true)
        fixture.runTurn(prompt: Self.firstPrompt, reply: Self.reply, toolCalls: [Self.toolCall])
        fixture.clock.advance(by: SessionRecapper.idleTime)
        try await fixture.recapper.jobChanges.wait(
            until: { !fixture.host.backend.calls.isEmpty }, endingOn: { fixture.recapper.jobCount == 0 })

        fixture.startTurn()
        fixture.host.backend.releaseHeldCalls()
        try await fixture.waitForTheEndOfTheJobs()

        #expect(fixture.host.writes.isEmpty)
    }

    // MARK: - A cancel during the write

    /// Runs a turn with a tool call, passes the idle time, and waits until
    /// the write of the recap waits at the gate of the host. The call ended
    /// and the job was not cancelled, so the write is the next step.
    ///
    /// - Returns: The fixture, with its write at the gate.
    /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
    private static func holdTheWrite() async throws -> Fixture {
        let fixture = makeFixture(holdsWrites: true)
        fixture.runTurn(prompt: firstPrompt, reply: reply, toolCalls: [toolCall])
        fixture.clock.advance(by: SessionRecapper.idleTime)
        try await fixture.recapper.jobChanges.wait(
            until: { fixture.host.heldWrites == 1 }, endingOn: { fixture.recapper.jobCount == 0 })
        return fixture
    }

    /// Opens the gate of the held write of `fixture` and waits for the end
    /// of the jobs.
    ///
    /// - Parameter fixture: The fixture of ``holdTheWrite()``.
    /// - Throws: ``ConditionNeverHeld`` when the test is cancelled first.
    private static func openTheWrite(of fixture: Fixture) async throws {
        fixture.host.openWriteGate()
        try await fixture.waitForTheEndOfTheJobs()
    }

    /// The production change that makes this test fail: a write that does
    /// not check, in one step with the write, that a new turn did not cancel
    /// the job.
    @Test("a new turn of the session during the write of the recap writes nothing")
    func aNewTurnDuringTheWriteWritesNothing() async throws {
        let fixture = try await Self.holdTheWrite()

        fixture.startTurn()
        try await Self.openTheWrite(of: fixture)

        #expect(fixture.host.writes.isEmpty)
    }

    /// The production change that makes this test fail: a cancelled write
    /// that removes the prompts of its input, so the next recap loses them.
    @Test("a new turn during the write of the recap keeps the prompts for the next recap")
    func aNewTurnDuringTheWriteKeepsThePrompts() async throws {
        let fixture = try await Self.holdTheWrite()
        fixture.startTurn()
        try await Self.openTheWrite(of: fixture)

        fixture.runTurn(prompt: Self.secondPrompt, reply: Self.reply, toolCalls: [Self.toolCall])
        try await fixture.passTheIdleTime()

        #expect(fixture.host.backend.calls.last?.prompt.contains(Self.firstPrompt) == true)
    }

    /// The production change that makes this test fail: a write that does
    /// not check, in one step with the write, that an archive or a close
    /// (``SessionRecapper/forget(_:)``) did not cancel the job.
    @Test("an archive or a close during the write of the recap writes nothing")
    func anArchiveDuringTheWriteWritesNothing() async throws {
        let fixture = try await Self.holdTheWrite()

        fixture.recapper.forget(fixture.session)
        try await Self.openTheWrite(of: fixture)

        #expect(fixture.host.writes.isEmpty)
    }

    /// The production change that makes this test fail: a write that does
    /// not check, in one step with the write, that a shutdown
    /// (``SessionRecapper/cancelAll()``) did not cancel the job.
    @Test("a shutdown during the write of the recap writes nothing")
    func aShutdownDuringTheWriteWritesNothing() async throws {
        let fixture = try await Self.holdTheWrite()

        fixture.recapper.cancelAll()
        try await Self.openTheWrite(of: fixture)

        #expect(fixture.host.writes.isEmpty)
    }
}
