import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task ^zfd8e69: the per-call binding layers post a typed
/// ``ToolInvocationRecord`` when a call opens and when it closes, and the
/// session actor delivers those records live as ``SessionEvent/toolInvocation(_:)``
/// — during the turn, not after it.
///
/// The identity rule these tests hold the design to (cards ^zn8n9md,
/// ^way106d): a record's ``ToolInvocationRecord/correlationID`` is the run's
/// `completionToken`, and it never appears inside a
/// ``SessionEvent/toolCall(id:name:argumentsJSON:)`` /
/// ``SessionEvent/toolStatus(id:status:summary:output:)`` id — those stay Apple's
/// `Transcript.ToolCall.id` space, derived by the post-turn diff.
@Suite("Tool invocation liveness: records from the binding layers, delivered mid-turn")
struct ToolInvocationLivenessTests {
    // MARK: - Fixtures

    /// An ``OperationEventSink`` that keeps every posted invocation record,
    /// so a binding-layer unit test can read back what one call posted.
    private actor RecordingInvocationSink: OperationEventSink {
        /// Every invocation record posted, in post order.
        private(set) var invocations: [ToolInvocationRecord] = []

        /// Every plain operation event posted, in post order.
        private(set) var operationEvents: [OperationEvent] = []

        func post(event: OperationEvent) {
            operationEvents.append(event)
        }

        func post(invocation record: ToolInvocationRecord) {
            invocations.append(record)
        }
    }

    /// A `String`-output test tool that does not return until the test
    /// releases it — the "slow scripted tool" the card's acceptance names.
    ///
    /// It records the step only *after* the gate opens, so an empty
    /// ``completedSteps`` proves the tool's own work has not completed yet.
    private final class GatedMarkerTool: Tool, Sendable {
        /// The model-facing tool name a scripted call names to reach this tool.
        static let toolName = "marker-gated"

        /// The `Tool` name requirement, bound to ``toolName``.
        let name = GatedMarkerTool.toolName

        /// The `Tool` description requirement — the SDK renders it into the
        /// tool definition it puts in the transcript.
        let description = "test-only tool that waits for the test's release before it returns"

        /// The steps whose work completed, recorded after the gate opened.
        private let callLog = MarkerToolCallLog()

        /// The signal ``call(arguments:)`` waits on before it does its work.
        private let releaseSignal: AsyncStream<Void>

        /// The test-side handle that opens the gate.
        private let releaseContinuation: AsyncStream<Void>.Continuation

        /// Every step whose work completed, in completion order.
        var completedSteps: [String] { callLog.calls }

        /// Creates the tool with its gate closed.
        init() {
            (releaseSignal, releaseContinuation) = AsyncStream.makeStream(of: Void.self)
        }

        /// Opens the gate, letting the in-flight (or a later) call complete.
        func release() {
            releaseContinuation.finish()
        }

        /// Waits for ``release()``, then records the step and returns its
        /// marker.
        ///
        /// - Parameter arguments: The call's decoded arguments; `value` is the
        ///   step name.
        /// - Returns: ``ScriptedToolFixture/marker(for:)`` for the named step.
        /// - Throws: Never — `throws` comes from the `Tool` requirement.
        func call(arguments: AmbientToolArguments) async throws -> String {
            for await _ in releaseSignal {}
            callLog.record(arguments.value)
            return ScriptedToolFixture.marker(for: arguments.value)
        }
    }

    // MARK: - The record itself

    @Test("closed(at:) keeps the record's identity and derives the duration")
    func closedRecordKeepsIdentityAndDerivesDuration() {
        let openedAt = Date(timeIntervalSince1970: 100)
        let closedAt = Date(timeIntervalSince1970: 103.5)
        let open = ToolInvocationRecord(
            tool: "search",
            op: "search",
            correlationID: "01AN4Z07BY79KA1307SR9X4MV3",
            sessionID: .generate(),
            openedAt: openedAt
        )

        #expect(open.closedAt == nil)
        #expect(open.duration == nil)

        let closed = open.closed(at: closedAt)
        #expect(closed.tool == open.tool)
        #expect(closed.op == open.op)
        #expect(closed.correlationID == open.correlationID)
        #expect(closed.sessionID == open.sessionID)
        #expect(closed.openedAt == openedAt)
        #expect(closed.closedAt == closedAt)
        #expect(closed.duration == 3.5)
    }

    // MARK: - The binding layers post open and close

    @Test("ContextBindingTool posts an open record before the call and a close record after it")
    func contextBindingToolPostsOpenAndCloseRecords() async throws {
        let sink = RecordingInvocationSink()
        let sessionID = ULID.generate()
        let wrapped = NonStringMarkerTool()
        let tool = ContextBindingTool(
            wrapping: wrapped, sessionID: sessionID, mailbox: SessionMailbox(), sink: sink)

        _ = try await tool.call(arguments: AmbientToolArguments(value: "ONE"))

        let records = await sink.invocations
        #expect(records.count == 2)
        let open = try #require(records.first)
        let closed = try #require(records.last)
        #expect(open.tool == NonStringMarkerTool.toolName)
        #expect(open.op == NonStringMarkerTool.toolName)
        #expect(open.sessionID == sessionID)
        #expect(open.closedAt == nil)
        #expect(closed.correlationID == open.correlationID)
        #expect(closed.openedAt == open.openedAt)
        #expect(closed.closedAt != nil)
        #expect(try #require(closed.duration) >= 0)
    }

    @Test("ContextBindingTool posts the close record when the wrapped tool throws")
    func contextBindingToolPostsCloseWhenTheWrappedToolThrows() async throws {
        let sink = RecordingInvocationSink()
        let tool = ContextBindingTool(
            wrapping: ThrowingMarkerTool(), sessionID: .generate(), mailbox: SessionMailbox(),
            sink: sink)

        await #expect(throws: ThrowingMarkerTool.CallFailure(step: "ONE")) {
            _ = try await tool.call(arguments: AmbientToolArguments(value: "ONE"))
        }

        let records = await sink.invocations
        #expect(records.count == 2)
        #expect(records.first?.closedAt == nil)
        #expect(records.last?.closedAt != nil)
        #expect(records.first?.correlationID == records.last?.correlationID)
    }

    @Test("RunToCompletionRunner posts open and close records around an in-band call, before the call returns")
    func runToCompletionToolPostsOpenAndCloseForAnInBandCall() async throws {
        let sink = RecordingInvocationSink()
        let wrapped = MarkerEmittingTool()
        let tool = RunToCompletionRunner(
            wrapping: wrapped, sessionID: .generate(), mailbox: SessionMailbox(), sink: sink,
            timeout: ToolMount.defaultTimeoutSeconds)

        let output = try await tool.call(arguments: AmbientToolArguments(value: "ONE"))
        #expect(output == ScriptedToolFixture.marker(for: "ONE"))

        // Both records were already delivered when the call returned — the
        // in-band ordering guarantee the live turn test relies on.
        let records = await sink.invocations
        #expect(records.count == 2)
        #expect(records.first?.tool == MarkerEmittingTool.toolName)
        #expect(records.first?.closedAt == nil)
        #expect(records.last?.closedAt != nil)
        #expect(records.first?.correlationID == records.last?.correlationID)
    }

    // MARK: - Live delivery during a real scripted turn

    @Test("a scripted tool turn delivers the open invocation event while the tool still runs, and every live record before turnEnded")
    @MainActor
    func liveInvocationEventArrivesWhileTheToolStillRuns() async throws {
        let slowTool = GatedMarkerTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-slow", toolName: GatedMarkerTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [slowTool],
            tempDirPrefix: "ToolInvocationLivenessTests")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let stream = await fixture.session.streamEvents(to: ScriptedToolFixture.prompt)
        var events: [SessionEvent] = []
        var openRecord: ToolInvocationRecord?
        var iterator = stream.makeAsyncIterator()
        while openRecord == nil, let event = try await iterator.next() {
            events.append(event)
            if case .toolInvocation(let record) = event, record.closedAt == nil {
                openRecord = record
            }
        }

        // The open event arrived, and the tool's own work has not completed:
        // the gate is still closed, so nothing can have been recorded.
        let open = try #require(openRecord)
        #expect(open.tool == GatedMarkerTool.toolName)
        #expect(slowTool.completedSteps.isEmpty)

        slowTool.release()
        while let event = try await iterator.next() {
            events.append(event)
        }

        // The tool completed once released.
        #expect(slowTool.completedSteps == [ScriptedToolFixture.firstStepName])

        // Ordering: open before close, close before the diff's .toolCall,
        // .toolCall before its completed .toolStatus, and every one of them
        // before turnEnded (when the backend reports usage at all).
        let openIndex = try #require(
            events.firstIndex {
                if case .toolInvocation(let record) = $0 { return record.closedAt == nil }
                return false
            })
        let closeIndex = try #require(
            events.firstIndex {
                if case .toolInvocation(let record) = $0 { return record.closedAt != nil }
                return false
            })
        let toolCallIndex = try #require(
            events.firstIndex {
                if case .toolCall = $0 { return true }
                return false
            })
        let completedIndex = try #require(
            events.firstIndex {
                if case .toolStatus(_, .completed, _, _) = $0 { return true }
                return false
            })
        #expect(openIndex < closeIndex)
        #expect(closeIndex < toolCallIndex)
        #expect(toolCallIndex < completedIndex)
        if let turnEndedIndex = events.firstIndex(where: {
            if case .turnEnded = $0 { return true }
            return false
        }) {
            #expect(completedIndex < turnEndedIndex)
        }

        // The diff's ids stay Apple's Transcript.ToolCall.id space: the
        // scripted call id, never the record's correlationID.
        guard case .toolCall(let id, let name, _) = events[toolCallIndex] else {
            Issue.record("expected a .toolCall at index \(toolCallIndex)")
            return
        }
        #expect(id == "call-slow")
        #expect(name == GatedMarkerTool.toolName)
        #expect(id != open.correlationID)

        // The close record pairs with the open record.
        guard case .toolInvocation(let closed) = events[closeIndex] else {
            Issue.record("expected a .toolInvocation at index \(closeIndex)")
            return
        }
        #expect(closed.correlationID == open.correlationID)
        #expect(try #require(closed.duration) >= 0)
    }

    @Test("invocation records are delivery-only: nothing extra is staged and nothing extra is recorded")
    @MainActor
    func invocationRecordsAreDeliveryOnlyAndChangeNoRecording() async throws {
        let markerTool = MarkerEmittingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1", toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [markerTool],
            tempDirPrefix: "ToolInvocationLivenessTests")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        var sawLiveInvocation = false
        for try await event in await fixture.session.streamEvents(to: ScriptedToolFixture.prompt) {
            if case .toolInvocation = event { sawLiveInvocation = true }
        }
        #expect(sawLiveInvocation)

        // Not staged: the outbox holds no pending event minted from an
        // invocation record — an in-band silent run posts no operation events,
        // and invocation records never become pending items.
        let pending = await fixture.session.outbox.pending()
        #expect(pending.events.isEmpty)

        // Not recorded: the persisted shape of a tool-using turn is exactly
        // what the post-turn diff alone records — the session meta line, then
        // the turn's own SDK entries (instructions included, the same shape
        // `ScriptedToolTurnComparisonTests` asserts on the raw transcript).
        // No invocation record reaches the recorder.
        let recordedKinds = await fixture.recorder.events.map(\.kind)
        #expect(recordedKinds == [.session, .instructions, .prompt, .toolCalls, .toolOutput, .response])
    }

    // MARK: - Projection phase

    @Test("the projection reports runningTool while an invocation is open, and generating once it closes")
    @MainActor
    func projectionReportsRunningToolWhileAnInvocationIsOpen() {
        let projection = SessionProjection()
        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
            openedAt: Date())

        projection.apply(.turnStarted(TurnStart(turnId: TurnID(1), promptId: nil)))
        projection.apply(.textDelta("thinking"))
        #expect(projection.phase == .generating)

        projection.apply(.toolInvocation(open))
        #expect(projection.phase == .runningTool)

        projection.apply(.toolInvocation(open.closed(at: Date())))
        #expect(projection.phase == .generating)
    }

    @Test("a background run's late close does not disturb an idle projection")
    @MainActor
    func lateCloseAfterTurnEndDoesNotDisturbAnIdleProjection() {
        let projection = SessionProjection()
        let open = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-1", sessionID: .generate(),
            openedAt: Date())

        projection.apply(.turnStarted(TurnStart(turnId: TurnID(1), promptId: nil)))
        projection.apply(.toolInvocation(open))
        projection.apply(.turnEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: 0.1)))
        #expect(projection.phase == .idle)

        projection.apply(.toolInvocation(open.closed(at: Date())))
        #expect(projection.phase == .idle)
    }

    @Test("a stale open from a prior turn does not pin the next turn's phase to runningTool")
    @MainActor
    func staleOpenFromAPriorTurnDoesNotPinTheNextTurn() {
        let projection = SessionProjection()
        let staleOpen = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-background", sessionID: .generate(),
            openedAt: Date())
        let quick = ToolInvocationRecord(
            tool: "search", op: "search", correlationID: "token-quick", sessionID: .generate(),
            openedAt: Date())

        // Turn 1 opens a run that stays in the background: no close arrives this turn.
        projection.apply(.turnStarted(TurnStart(turnId: TurnID(1), promptId: nil)))
        projection.apply(.toolInvocation(staleOpen))
        projection.apply(.turnEnded(TokenUsage(tokensIn: 1, tokensOut: 1, contextFill: 0.1)))

        // Turn 2 runs one quick call; its close alone returns the phase to
        // generating, with the stale open from turn 1 no longer counted.
        projection.apply(.turnStarted(TurnStart(turnId: TurnID(2), promptId: nil)))
        projection.apply(.toolInvocation(quick))
        #expect(projection.phase == .runningTool)
        projection.apply(.toolInvocation(quick.closed(at: Date())))
        #expect(projection.phase == .generating)
    }

    // MARK: - Tool call reports: delivered live on the turn's stream, or on the session feed

    /// Keeps every event a session-scoped stream carries, in arrival order, so
    /// a test can wait for a report under a bound instead of on the stream
    /// itself, and can then read the order of a close record and its report.
    private actor SessionEventLog {
        /// Every event seen, in arrival order.
        private(set) var events: [SessionEvent] = []

        /// Every report seen, in arrival order.
        var reports: [ToolCallReport] { events.compactMap(\.carriedReport) }

        /// Records one event.
        ///
        /// - Parameter event: The event the stream carried.
        func record(_ event: SessionEvent) {
            events.append(event)
        }
    }

    /// Builds the report a test posts for one closed call, with the same
    /// identity the call's close record carries.
    ///
    /// - Parameter record: The call's close record.
    /// - Returns: A report for that call, carrying one attachment.
    private static func report(for record: ToolInvocationRecord) -> ToolCallReport {
        ToolCallReport(
            tool: record.tool, op: record.op, correlationID: record.correlationID,
            sessionID: record.sessionID, attachments: [MountFixtures.firstAttachment])
    }

    /// The position of the first ``SessionEvent/turnEnded(_:)`` in `events`,
    /// or `nil` when the backend reported no usage.
    ///
    /// - Parameter events: The turn's events, in stream order.
    /// - Returns: The index of the first `turnEnded`, or `nil`.
    private static func turnEndedIndex(in events: [SessionEvent]) -> Int? {
        events.firstIndex {
            if case .turnEnded = $0 { return true }
            return false
        }
    }

    @Test("a report posted mid-turn arrives on the turn's stream after the close record it follows")
    @MainActor
    func reportPostedMidTurnArrivesOnTheTurnStreamAfterTheCloseRecord() async throws {
        let quickTool = MarkerEmittingTool()
        let slowTool = GatedMarkerTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-quick", toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ],
                [
                    ScriptedToolCall(
                        id: "call-slow", toolName: GatedMarkerTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ],
            ]),
            mounting: [quickTool, slowTool],
            tempDirPrefix: "ToolInvocationLivenessTests")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // Read the turn's stream up to the quick call's close record. The gated
        // call of the second round has not returned, so the turn is in flight
        // when the report is posted.
        let stream = await fixture.session.streamEvents(to: ScriptedToolFixture.prompt)
        var events: [SessionEvent] = []
        var quickClose: ToolInvocationRecord?
        var iterator = stream.makeAsyncIterator()
        while quickClose == nil, let event = try await iterator.next() {
            events.append(event)
            if case .toolInvocation(let record) = event,
                record.tool == MarkerEmittingTool.toolName, record.closedAt != nil
            {
                quickClose = record
            }
        }
        let close = try #require(quickClose)
        let closeIndex = events.count - 1

        let report = Self.report(for: close)
        await fixture.session.outbox.post(report: report)

        slowTool.release()
        while let event = try await iterator.next() {
            events.append(event)
        }

        let reportIndex = try #require(events.firstIndex(of: .toolCallReport(report)))
        #expect(closeIndex < reportIndex)
        if let turnEndedIndex = Self.turnEndedIndex(in: events) {
            #expect(reportIndex < turnEndedIndex)
        }
    }

    @Test("a report posted between turns arrives on streamSessionEvents()")
    @MainActor
    func reportPostedBetweenTurnsArrivesOnTheSessionStream() async throws {
        let fixture = try await ScriptedSessionFixture.make(
            playing: ScriptedTurnScript(rounds: [
                [
                    ScriptedToolCall(
                        id: "call-1", toolName: MarkerEmittingTool.toolName,
                        argument: .literal(ScriptedToolFixture.firstStepName))
                ]
            ]),
            mounting: [MarkerEmittingTool()],
            tempDirPrefix: "ToolInvocationLivenessTests")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // One turn first: the session installs itself as the outbox's observer
        // at the top of its first turn. A report posted before that is dropped.
        let outcome: TurnOutcome = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        let close = try #require(outcome.toolInvocations.first)

        let log = SessionEventLog()
        let sessionEvents = await fixture.session.streamSessionEvents()
        let collecting = Task {
            for await event in sessionEvents {
                await log.record(event)
            }
        }
        defer { collecting.cancel() }

        let report = Self.report(for: close)
        await fixture.session.outbox.post(report: report)

        #expect(
            await BoundedWait.conditionReached("the report on streamSessionEvents()") {
                await log.reports == [report]
            })
    }

    // MARK: - Tool call reports from the decorators: a closing call's attachments reach the stream

    /// The temp directory prefix every fixture of this suite is built with.
    private static let tempDirPrefix = "ToolInvocationLivenessTests"

    /// One scripted round that calls `tool` one time, naming
    /// ``ScriptedToolFixture/firstStepName``.
    ///
    /// - Parameter tool: The tool the one call names.
    /// - Returns: The one-round script.
    private static func oneCallScript(calling tool: any Tool) -> ScriptedTurnScript {
        ScriptedTurnScript(rounds: [
            [
                ScriptedToolCall(
                    id: "call-1", toolName: tool.name,
                    argument: .literal(ScriptedToolFixture.firstStepName))
            ]
        ])
    }

    /// Asserts that `events` open the one call before they close it.
    ///
    /// - Parameter events: The events to read, in stream order.
    /// - Throws: When an open record or a close record is missing.
    private static func expectOpenPrecedesClose(in events: [SessionEvent]) throws {
        let openIndex = try #require(events.firstIndex { $0.isOpenInvocation })
        let closeIndex = try #require(events.firstIndex { $0.isCloseInvocation })
        #expect(openIndex < closeIndex)
    }

    /// Asserts that `events` carry one close record and then exactly one
    /// report, for the same call, and that the report carries
    /// ``MountFixtures/attachmentsInCallOrder``.
    ///
    /// - Parameter events: The events to read, in stream order.
    /// - Throws: When the close record or the report is missing.
    private static func expectOneReportFollowsClose(in events: [SessionEvent]) throws {
        let closeIndex = try #require(events.firstIndex { $0.isCloseInvocation })
        let reportIndex = try #require(events.firstIndex { $0.carriedReport != nil })
        #expect(closeIndex < reportIndex)
        #expect(events.compactMap(\.carriedReport).count == 1)
        guard case .toolInvocation(let close) = events[closeIndex],
            let report = events[reportIndex].carriedReport
        else {
            Issue.record("expected the close record at \(closeIndex) and the report at \(reportIndex)")
            return
        }
        #expect(report.correlationID == close.correlationID)
        #expect(report.tool == close.tool)
        #expect(report.op == close.op)
        #expect(report.sessionID == close.sessionID)
        #expect(report.attachments == MountFixtures.attachmentsInCallOrder)
    }

    /// Drives one scripted turn that calls `tool` one time, and asserts the
    /// turn's stream carries the open record, the close record, and then one
    /// report for that call.
    ///
    /// - Parameter tool: The in-band attaching tool the one call names.
    /// - Throws: Whatever the fixture or the turn throws.
    private static func expectInBandCallReportsItsAttachments(calling tool: any Tool) async throws {
        let fixture = try await ScriptedSessionFixture.make(
            playing: oneCallScript(calling: tool), mounting: [tool], tempDirPrefix: tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        try expectOpenPrecedesClose(in: events)
        try expectOneReportFollowsClose(in: events)
    }

    @Test("a run-to-completion call that attaches produces open, close, then one report under the same correlationID on the turn's stream")
    @MainActor
    func runToCompletionCallReportsItsAttachmentsOnTheTurnStream() async throws {
        try await Self.expectInBandCallReportsItsAttachments(calling: MountFixtures.AttachingTool())
    }

    @Test("a ContextBindingTool call that attaches produces open, close, then one report under the same correlationID on the turn's stream")
    @MainActor
    func contextBindingToolCallReportsItsAttachmentsOnTheTurnStream() async throws {
        try await Self.expectInBandCallReportsItsAttachments(
            calling: MountFixtures.AttachingNonStringOutputTool())
    }

    @Test("a background call that attaches produces its report on streamSessionEvents() after the close record, when the run settles")
    @MainActor
    func backgroundCallReportsItsAttachmentsOnTheSessionStreamWhenItSettles() async throws {
        let gate = RunLatch()
        let tool = MountFixtures.DeclaredBackgroundAttachingTool(gate: gate)
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.oneCallScript(calling: tool), mounting: [tool], tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        // The turn returns while the run waits on its gate, so the close record
        // and the report can only arrive on the session stream.
        let outcome: TurnOutcome = try await fixture.session.respond(to: ScriptedToolFixture.prompt)
        let open = try #require(outcome.toolInvocations.first)
        #expect(open.closedAt == nil)

        let log = SessionEventLog()
        let sessionEvents = await fixture.session.streamSessionEvents()
        let collecting = Task {
            for await event in sessionEvents {
                await log.record(event)
            }
        }
        defer { collecting.cancel() }

        // The run posts its close record and its report before it settles,
        // so the settlement wait bounds the run's work, and the spin below
        // covers only the hop from the stream to the log.
        await gate.open()
        _ = await fixture.session.mailbox.wait(
            completionToken: open.correlationID, seconds: MountFixtures.settlementDeadline)
        #expect(
            await BoundedWait.conditionReached("the report on streamSessionEvents()") {
                await log.reports.count == 1
            })

        let events = await log.events
        try Self.expectOneReportFollowsClose(in: events)
        #expect(events.compactMap(\.carriedReport).map(\.correlationID) == [open.correlationID])
    }

    @Test("a call that attaches nothing produces no toolCallReport")
    @MainActor
    func callWithNoAttachmentsProducesNoReport() async throws {
        let tool = MarkerEmittingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.oneCallScript(calling: tool), mounting: [tool], tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        // The call ran and closed; only the report is absent.
        try Self.expectOpenPrecedesClose(in: events)
        #expect(events.compactMap(\.carriedReport).isEmpty)
    }

    @Test("a report is delivery-only: the outbox stages nothing for it and the recorder holds no event for it")
    @MainActor
    func reportIsNeverStagedOrRecorded() async throws {
        let tool = MountFixtures.AttachingTool()
        let fixture = try await ScriptedSessionFixture.make(
            playing: Self.oneCallScript(calling: tool), mounting: [tool], tempDirPrefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let events = try await collectEvents(fixture.session, prompt: ScriptedToolFixture.prompt)

        // The positive control: the report was delivered live.
        #expect(events.compactMap(\.carriedReport).count == 1)
        let pending = await fixture.session.outbox.pending()
        #expect(pending.events.isEmpty)
        // The persisted shape is the one the post-turn diff alone records, the
        // same shape `invocationRecordsAreDeliveryOnlyAndChangeNoRecording`
        // asserts for a turn with no attachments.
        let recordedKinds = await fixture.recorder.events.map(\.kind)
        #expect(recordedKinds == [.session, .instructions, .prompt, .toolCalls, .toolOutput, .response])
    }

    @Test("a ToolRun whose sink is a plain OperationEventSink drops the report without a trap and still posts both records")
    func plainSinkDropsTheReportWithoutATrap() async throws {
        let sink = RecordingInvocationSink()
        let arguments = MountArguments(value: "x")
        let run = MountFixtures.toolRun(wrapping: MountFixtures.AttachingTool(), arguments: arguments, sink: sink)

        await run.open()
        let settlement = await run.execute(arguments: arguments)

        // The call attached, so a report was due; the plain sink is not a
        // `ToolCallReportSink`, so the report went nowhere. Both records
        // still arrived, and nothing trapped.
        #expect(settlement.attachments == MountFixtures.attachmentsInCallOrder)
        #expect(await sink.invocations.map { $0.closedAt == nil } == [true, false])
        #expect(await sink.operationEvents.isEmpty)
    }

    // MARK: - The shared report post behind both decorators

    /// One closed call's record, with a fresh identity, for a direct call of
    /// `postToolCallReport(closing:attachments:)`.
    ///
    /// - Returns: The close record.
    private static func makeClosedRecord() -> ToolInvocationRecord {
        ToolInvocationRecord(
            tool: "search", op: "search", correlationID: SessionMailbox.makeCompletionToken(),
            sessionID: .generate(), openedAt: Date()
        ).closed(at: Date())
    }

    @Test("postToolCallReport(closing:attachments:) posts one report with the close record's identity to a ToolCallReportSink")
    func sharedReportPostDeliversToAReportSink() async throws {
        let recording = MountFixtures.RecordingSink()
        // Typed the way the decorators hold their sink, so the call goes
        // through the dynamic cast the helper exists for.
        let sink: any OperationEventSink = recording
        let close = Self.makeClosedRecord()

        await sink.postToolCallReport(closing: close, attachments: MountFixtures.attachmentsInCallOrder)

        let reports = await recording.reports
        let report = try #require(reports.first)
        #expect(reports.count == 1)
        #expect(report.correlationID == close.correlationID)
        #expect(report.tool == close.tool)
        #expect(report.op == close.op)
        #expect(report.sessionID == close.sessionID)
        #expect(report.attachments == MountFixtures.attachmentsInCallOrder)
    }

    @Test("postToolCallReport(closing:attachments:) posts nothing for a call that attached nothing")
    func sharedReportPostSkipsACallWithNoAttachments() async {
        let recording = MountFixtures.RecordingSink()
        let sink: any OperationEventSink = recording

        await sink.postToolCallReport(closing: Self.makeClosedRecord(), attachments: [])

        #expect(await recording.reports.isEmpty)
    }

    @Test("postToolCallReport(closing:attachments:) drops the report on a sink that is not a ToolCallReportSink, without a trap")
    func sharedReportPostDropsOnAPlainSink() async {
        let recording = RecordingInvocationSink()
        let sink: any OperationEventSink = recording

        await sink.postToolCallReport(
            closing: Self.makeClosedRecord(), attachments: MountFixtures.attachmentsInCallOrder)

        // The plain sink is not a `ToolCallReportSink`, so the report went
        // nowhere, and nothing else reached the sink either.
        #expect(await recording.operationEvents.isEmpty)
        #expect(await recording.invocations.isEmpty)
    }
}

