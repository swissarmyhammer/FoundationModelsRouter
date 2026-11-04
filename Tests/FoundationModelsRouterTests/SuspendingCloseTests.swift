import Foundation
import FoundationModels
import FoundationModelsExtras
import Operations
import Testing

@testable import FoundationModelsRouter

/// The tool of this file and of ``CancelForegroundTests``: five background operations of one `OperationTool`.
/// A body waits until the host cancels its run, or until the gate of the
/// context opens, and then ends in its own way.
enum ShutdownRunFixtures {
    /// The name of the fused tool.
    static let toolName = "shutdown_agents"

    /// The text that the body of ``SwallowCancelRun`` returns after the cancel.
    static let swallowedText = "The agent was cancelled."

    /// The context of each operation.
    struct Context: Sendable {
        /// The latch that the body of ``IgnoreCancelRun`` waits on. A test
        /// decides when that body ends.
        let gate: RunLatch
    }

    /// The output of an operation that returns text.
    struct Output: Encodable, Sendable {
        /// The text of the result.
        let result: String
    }

    /// The error of ``ThrowLostRun``: the work is gone and nothing observes it.
    struct WorkGone: LostRunError {}

    /// Waits until the task of the caller is cancelled. The wait ends only at
    /// the cancel, so a body that calls it holds its run open until then.
    static func waitForCancel() async {
        let latch = RunLatch()
        await withTaskCancellationHandler {
            await latch.waitUntilOpen()
        } onCancel: {
            Task { await latch.open() }
        }
    }

    /// Makes the fused tool over the five operations.
    ///
    /// - Parameter gate: The latch of the body of ``IgnoreCancelRun``.
    /// - Returns: The tool.
    /// - Throws: What `OperationTool.init` throws when the schemas do not fuse.
    static func makeTool(gate: RunLatch) throws -> OperationTool<Context> {
        try OperationTool(
            name: toolName,
            description: "runs agents whose bodies end in different ways",
            context: Context(gate: gate),
            operations: [
                AnyOperation(SwallowCancelRun.self), AnyOperation(ThrowCancellationRun.self),
                AnyOperation(ThrowLostRun.self), AnyOperation(IgnoreCancelRun.self),
                AnyOperation(AskQuestionRun.self),
            ]
        )
    }

    /// The JSON arguments of one call of the tool.
    ///
    /// - Parameters:
    ///   - op: The `"verb noun"` of the called operation.
    ///   - name: The name of the agent.
    /// - Returns: The arguments as a JSON object.
    static func arguments(op: String, name: String) -> String {
        AgentOperationFixtures.arguments(op: op, name: name)
    }
}

/// A background run whose body swallows the cancel and returns text.
@Generable
@Operation(verb: "swallow", noun: "cancel", description: "Swallow the cancel", mount: ToolMount(mode: .background))
struct SwallowCancelRun {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension SwallowCancelRun {
    /// Waits for the cancel, then returns text.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The text ``ShutdownRunFixtures/swallowedText``.
    func execute(in context: ShutdownRunFixtures.Context) async throws -> ShutdownRunFixtures.Output {
        await ShutdownRunFixtures.waitForCancel()
        return ShutdownRunFixtures.Output(result: ShutdownRunFixtures.swallowedText)
    }
}

/// A background run whose body throws `CancellationError` at the cancel.
@Generable
@Operation(verb: "throw", noun: "cancellation", description: "Throw the cancellation", mount: ToolMount(mode: .background))
struct ThrowCancellationRun {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension ThrowCancellationRun {
    /// Waits for the cancel, then throws `CancellationError`.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: Nothing: the body always throws.
    func execute(in context: ShutdownRunFixtures.Context) async throws -> ShutdownRunFixtures.Output {
        await ShutdownRunFixtures.waitForCancel()
        throw CancellationError()
    }
}

/// A background run whose body throws a `LostRunError` at the cancel.
@Generable
@Operation(verb: "throw", noun: "lost", description: "Throw the lost error", mount: ToolMount(mode: .background))
struct ThrowLostRun {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension ThrowLostRun {
    /// Waits for the cancel, then throws ``ShutdownRunFixtures/WorkGone``.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: Nothing: the body always throws.
    func execute(in context: ShutdownRunFixtures.Context) async throws -> ShutdownRunFixtures.Output {
        await ShutdownRunFixtures.waitForCancel()
        throw ShutdownRunFixtures.WorkGone()
    }
}

/// A background run whose body ignores the cancel. It returns text when the
/// gate of the context opens, so a test decides when the body ends.
@Generable
@Operation(verb: "ignore", noun: "cancel", description: "Ignore the cancel", mount: ToolMount(mode: .background))
struct IgnoreCancelRun {
    /// The name of the agent.
    @Guide(description: "The agent name")
    var name: String
}

extension IgnoreCancelRun {
    /// Waits for the gate, then returns text.
    ///
    /// - Parameter context: The shared context.
    /// - Returns: The text ``ShutdownRunFixtures/swallowedText``.
    func execute(in context: ShutdownRunFixtures.Context) async throws -> ShutdownRunFixtures.Output {
        await context.gate.waitUntilOpen()
        return ShutdownRunFixtures.Output(result: ShutdownRunFixtures.swallowedText)
    }
}

/// Where a run is when the host ends the session.
enum RunPlacement: CaseIterable, CustomStringConvertible {
    /// The call returned its pending envelope: the run is past the settle
    /// period.
    case pastGrace

    /// The call still waits for its run inside the settle period.
    case inline

    var description: String {
        switch self {
        case .pastGrace: "past the settle period"
        case .inline: "inline"
        }
    }
}

/// A recorded session whose scripted model calls the tool of
/// ``ShutdownRunFixtures``, on a real run plane, with the recording on disk.
///
/// The settle period is the ``MountFixtures/manualClockGrace`` on a
/// ``ManualRunClock``, so a call stays inline until the test advances the
/// clock. A second router stands in for the new process: it has the id of the
/// first router and shares its recorder, as the other restore suites do, so
/// it can read the recording and also write to it.
struct ShutdownRecording {
    /// The prefix of the temporary folders of each test.
    private static let folderPrefix = "SuspendingCloseTests"

    /// The prompt of the submission that calls the tool.
    static let startPrompt = "start the agents"

    /// The name of the agent of each call.
    static let agentName = "scout"

    /// The cache folder and the recordings folder of the test.
    let directories: TestDirectories

    /// The router that records the session.
    let recordingRouter: Router

    /// The router of the "new process", which restores the session.
    let restoringRouter: Router

    /// The resolved profile of ``restoringRouter``.
    let restoringProfile: LanguageModelProfile

    /// The recorded session.
    let session: any RoutedSession

    /// The clock of the run plane of the session.
    let clock: ManualRunClock

    /// The latch of the body of ``IgnoreCancelRun``.
    let gate: RunLatch

    /// The tool of the session, which a restore gets again.
    let tool: OperationTool<ShutdownRunFixtures.Context>

    /// The directory of the second router, which reads the journal.
    var directory: RouterSessionDirectory { restoringRouter.sessionDirectory }

    /// Makes a recorded session whose model calls `ops`, one call in each
    /// round, in order.
    ///
    /// - Parameter ops: The `"verb noun"` of each call.
    /// - Returns: The recording. The caller ends it with ``end()``.
    /// - Throws: What the make of the routers or of the tool throws.
    static func make(calling ops: [String]) async throws -> Self {
        let rounds = ops.enumerated().map { index, op in
            [
                ScriptedToolCall(
                    id: "call-\(index)", toolName: ShutdownRunFixtures.toolName,
                    argument: .json(ShutdownRunFixtures.arguments(op: op, name: agentName)))
            ]
        }
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: rounds), log: ScriptedAnswerLog()))
        let directories = TestDirectories(prefix: folderPrefix)
        let recorder = JSONLRecorder(directory: directories.recordingsDir)
        let clock = ManualRunClock()
        let recordingRouter = makeRouter(over: container, in: directories, recorder: recorder)
        await recordingRouter.useRunClock(clock)
        let restoringRouter = makeRouter(
            over: BasicLLMContainer(), in: directories, recorder: recorder, id: recordingRouter.id)
        let (profile, restoringProfile) = try await RouterTestFixtures.removingDirectoryOnThrow(
            directories.cacheDir, alsoOnThrow: { directories.remove() }
        ) {
            let profile = try await recordingRouter.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let restoring = try await restoringRouter.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return (profile, restoring)
        }
        let gate = RunLatch()
        let tool = try ShutdownRunFixtures.makeTool(gate: gate)
        let session = profile.standard.makeSession(
            configuration: SessionConfiguration(tools: [tool], inlineSettleGrace: MountFixtures.manualClockGrace))
        return Self(
            directories: directories, recordingRouter: recordingRouter, restoringRouter: restoringRouter,
            restoringProfile: restoringProfile, session: session, clock: clock, gate: gate, tool: tool)
    }

    /// Makes a router over `container` in `directories`.
    private static func makeRouter(
        over container: any LoadedLLMContainer, in directories: TestDirectories, recorder: JSONLRecorder,
        id: ULID = .generate()
    ) -> Router {
        RouterTestFixtures.makeRouter(
            id: id, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
    }

    /// Starts the submission that calls the tool.
    ///
    /// - Returns: The task of the answer.
    func startAnswering() -> Task<String, any Error> {
        let session = session
        return Task { try await session.respond(to: Self.startPrompt) }
    }

    /// Waits until the call that `answering` runs waits for its run inside the
    /// settle period.
    ///
    /// - Parameter answering: The task of the answer.
    /// - Throws: ``FailureEventCameFirst`` when the answer ended first.
    func awaitInlineCall(of answering: Task<String, any Error>) async throws {
        try await clock.waitForSleepers(atLeast: 1, endingOnEndOf: answering)
    }

    /// Ends the settle period of the call that waits now, so its run goes on
    /// past the period behind a pending envelope.
    func endSettlePeriod() {
        clock.advance(by: .seconds(MountFixtures.manualClockGrace))
    }

    /// Starts the answer and brings the one run of the recording to
    /// `placement`: a run past the settle period, or a call that still waits
    /// inline.
    ///
    /// - Parameter placement: Where the run is.
    /// - Returns: The task of the answer.
    /// - Throws: ``FailureEventCameFirst`` when the answer ended first.
    func startRun(at placement: RunPlacement) async throws -> Task<String, any Error> {
        let answering = startAnswering()
        try await awaitInlineCall(of: answering)
        if placement == .pastGrace {
            endSettlePeriod()
            _ = try await answering.value
        }
        return answering
    }

    /// The status of each run in the journal of the session, read by the
    /// second router from disk.
    ///
    /// - Returns: The statuses.
    /// - Throws: What the read throws.
    func statuses() async throws -> [RunKey: RunStatus] {
        await directory.useRecordingRoots { [recordingRoot] }
        return try await directory.runStatuses(of: session.id)
    }

    /// The recording root of the session: the folder that holds its folder.
    var recordingRoot: URL {
        session.recordingDirectory.deletingLastPathComponent()
    }

    /// Opens the gate, closes the session and removes the folders.
    func end() async {
        await SessionFixtureLifecycle.close(session, opening: [gate])
        directories.remove()
    }
}

/// What a normal `close()` writes into the journal for a run that the host
/// stops, for each way a body can end at the cancel.
///
/// The close is the close that the user asks for, for example the close of
/// an ACP session. It cancels the work, and the run ends. The runs are real:
/// an `OperationTool` on a real run plane, started by a scripted model.
///
/// **What the journal holds, measured with these tests.** The sweep of the
/// close and the body of the run both write the terminal event of the run,
/// and the first write wins. The winner depends on scheduling, so a body that
/// reacts to the cancel gets one of two outcomes, and both were measured:
///
/// - A body that swallows the cancel and returns text: `cancelled` (the sweep
///   won) or `succeeded` (the body won).
/// - A body that throws `CancellationError`: `cancelled`. `AnyOperation`
///   rethrows the error, and the one outcome rule
///   (`OperationOutcome(thrown:)`) gives `cancelled` for it. So the sweep and
///   the body write the same outcome.
/// - A body that throws a `LostRunError`: `cancelled` (the sweep won) or
///   `lost` (the body won). `AnyOperation` rethrows the error, and the one
///   outcome rule gives `lost` for it.
///
/// A body that waits until the sweep settled the run has one outcome:
/// `cancelled`.
@Suite("A normal close: what the journal holds for a run that the host stops")
struct NormalCloseRunOutcomeTests {
    /// One way a body can end at the cancel, with the outcomes that the
    /// journal can hold for it.
    struct Reaction: CustomStringConvertible {
        /// The `"verb noun"` of the operation.
        let op: String

        /// What the body does at the cancel.
        let description: String

        /// The outcomes that the race of the two writers can give.
        let possible: [OperationOutcome]
    }

    /// Each way a body can end at the cancel.
    static let reactions = [
        Reaction(op: "swallow cancel", description: "returns text", possible: [.cancelled, .succeeded]),
        Reaction(op: "throw cancellation", description: "throws CancellationError", possible: [.cancelled]),
        Reaction(op: "throw lost", description: "throws a LostRunError", possible: [.cancelled, .lost]),
    ]

    @Test("a run that the sweep settled first is cancelled, also when the body returns text after it", arguments: RunPlacement.allCases)
    func sweepWinsOverALateBody(placement: RunPlacement) async throws {
        let recording = try await ShutdownRecording.make(calling: ["ignore cancel"])
        defer { await recording.end() }
        let actor = try #require(recording.session as? RoutedSessionActor)
        let answering = try await recording.startRun(at: placement)

        let closing = Task { await recording.session.close() }
        // The journal holds the write of the sweep. The body of the run waits
        // for the gate, so the close cannot end before the gate opens.
        try await actor.idleChanges.wait(
            until: { await !actor.journaledTerminalCorrelationIDs.isEmpty }, endingOnEndOf: closing)
        await recording.gate.open()
        await closing.value
        _ = try? await answering.value

        #expect(try await recording.statuses().values.map { $0 } == [.completed(.cancelled)])
    }

    @Test("a body that reacts to the cancel gets one of the outcomes of the two writers", arguments: reactions)
    func reactingBodyGetsAnOutcomeOfTheRace(reaction: Reaction) async throws {
        let recording = try await ShutdownRecording.make(calling: [reaction.op])
        defer { await recording.end() }
        let answering = try await recording.startRun(at: .pastGrace)

        await recording.session.close()
        _ = try? await answering.value

        let outcomes = try await recording.statuses().values.map { $0 }
        #expect(outcomes.count == 1)
        #expect(
            outcomes.allSatisfy { status in
                guard case .completed(let outcome) = status else { return false }
                return reaction.possible.contains(outcome)
            })
    }
}

/// A suspending close for an orderly quit of the process: the runs that are
/// open stay open in the journal, so a restore finds them as orphans, and a
/// host that claims them completes the original calls with the real result.
///
/// The runs are real: an `OperationTool` on a real run plane, started by a
/// scripted model. One run is past the settle period, and one call still
/// waits inline. A second router over the same recordings folder reads the
/// journal from disk and restores the session, as the new process does.
@Suite("A suspending close leaves the open runs open for a restore")
struct SuspendingCloseTests {
    /// The operation of the two runs that the tests leave open.
    private static let openRunOp = "swallow cancel"

    /// The detail that the host gives to the completion of a claimed run.
    private static let completionDetail = "the agent finished after the restart"

    // MARK: - Helpers

    /// Starts the answer that calls the tool two times, and waits until one
    /// run is past the settle period and the other call still waits inline.
    ///
    /// - Parameter recording: A recording made for two calls.
    /// - Returns: The task of the answer, which ends when the session ends.
    /// - Throws: ``FailureEventCameFirst`` when the answer ended first.
    static func openTwoRuns(in recording: ShutdownRecording) async throws -> Task<String, any Error> {
        let answering = recording.startAnswering()
        try await recording.awaitInlineCall(of: answering)
        recording.endSettlePeriod()
        try await recording.awaitInlineCall(of: answering)
        return answering
    }

    /// Suspends the session of `recording`, closes it, and waits for the end
    /// of `answering`.
    static func suspendAndClose(_ recording: ShutdownRecording, ending answering: Task<String, any Error>) async {
        recording.session.suspend()
        await recording.session.close()
        _ = try? await answering.value
    }

    /// Restores the suspended session of `recording` under the second router,
    /// with a claim for each run of the journal.
    ///
    /// - Parameter recording: A recording that was suspended and closed.
    /// - Returns: The restored tree.
    /// - Throws: What the status read or the restore throws.
    static func restoreClaimingEveryRun(of recording: ShutdownRecording) async throws -> RestoredSessionTree {
        let keys = Set(try await recording.statuses().keys)
        return try await recording.restoringProfile.standard.restoreSessionTree(
            root: recording.session.id, recordingRoot: recording.recordingRoot,
            tools: [recording.tool], claimingRuns: keys)
    }

    /// The ids of the tool calls, and of the tool outputs, of `entries`. The
    /// outputs hold also the rows of the run events, which a restore rebuilds
    /// as `.toolOutput` entries with an id of their own.
    private static func callAndOutputIDs(in entries: [Transcript.Entry]) -> (calls: [String], outputs: [String]) {
        var calls: [String] = []
        var outputs: [String] = []
        for entry in entries {
            switch entry {
            case .toolCalls(let toolCalls): calls += toolCalls.map(\.id)
            case .toolOutput(let output): outputs.append(output.id)
            default: break
            }
        }
        return (calls, outputs)
    }

    // MARK: - The journal after the suspend

    @Test("a run past the settle period and a call still inline are orphans after a suspending close")
    func openRunsAreOrphans() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.openRunOp, Self.openRunOp])
        defer { await recording.end() }
        let answering = try await Self.openTwoRuns(in: recording)

        await Self.suspendAndClose(recording, ending: answering)

        let statuses = try await recording.statuses()
        #expect(statuses.count == 2)
        #expect(statuses.values.allSatisfy { $0 == .orphaned })
    }

    @Test("a body that returns text after the suspend does not make its run succeeded", arguments: RunPlacement.allCases)
    func lateBodyDoesNotWin(placement: RunPlacement) async throws {
        let recording = try await ShutdownRecording.make(calling: ["ignore cancel"])
        defer { await recording.end() }
        let answering = try await recording.startRun(at: placement)

        recording.session.suspend()
        let closing = Task { await recording.session.close() }
        await recording.gate.open()
        await closing.value
        _ = try? await answering.value

        #expect(try await recording.statuses().values.map { $0 } == [.orphaned])
    }

    @Test("a suspend of the directory suspends each live session")
    func directorySuspendsLiveSessions() async throws {
        let recording = try await ShutdownRecording.make(calling: ["ignore cancel"])
        defer { await recording.end() }
        let answering = try await recording.startRun(at: .inline)

        recording.recordingRouter.sessionDirectory.suspendLiveSessions()
        let closing = Task { await recording.session.close() }
        await recording.gate.open()
        await closing.value
        _ = try? await answering.value

        #expect(try await recording.statuses().values.map { $0 } == [.orphaned])
    }

    @Test("a mark after the suspend writes no marker, so the restore finds the session unended and its calls orphaned")
    func markAfterSuspendLeavesTheSessionRestorable() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.openRunOp, Self.openRunOp])
        defer { await recording.end() }
        let answering = try await Self.openTwoRuns(in: recording)
        recording.recordingRouter.sessionDirectory.suspendLiveSessions()

        await #expect(throws: SessionEndedMarkerError.sessionSuspended(recording.session.id)) {
            try await recording.recordingRouter.sessionDirectory.markEnded(recording.session.id, reason: .finished)
        }
        await recording.session.close()
        _ = try? await answering.value

        #expect(try await recording.statuses().values.allSatisfy { $0 == .orphaned })
        #expect(try await recording.directory.endMarker(of: recording.session.id) == nil)
    }

    // MARK: - The restore

    @Test("a restore accepts a claim for each open run, and the host completes both original runs")
    func hostCompletesTheClaimedRuns() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.openRunOp, Self.openRunOp])
        defer { await recording.end() }
        let answering = try await Self.openTwoRuns(in: recording)
        await Self.suspendAndClose(recording, ending: answering)
        let keys = try await recording.statuses().keys
        let tree = try await Self.restoreClaimingEveryRun(of: recording)
        defer { await SessionFixtureLifecycle.close(tree) }

        var accepted: [Bool] = []
        for key in keys {
            accepted.append(await tree.root.completeClaimedRun(key, outcome: .succeeded, detail: Self.completionDetail))
        }

        #expect(accepted == [true, true])
        #expect(try await recording.statuses().values.map { $0 } == [.completed(.succeeded), .completed(.succeeded)])
    }

    @Test("the transcript of the restored session answers each tool call")
    func transcriptIsValidAfterTheRestore() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.openRunOp, Self.openRunOp])
        defer { await recording.end() }
        let answering = try await Self.openTwoRuns(in: recording)
        await Self.suspendAndClose(recording, ending: answering)
        let tree = try await Self.restoreClaimingEveryRun(of: recording)
        defer { await SessionFixtureLifecycle.close(tree) }

        let ids = Self.callAndOutputIDs(in: Array(await tree.root.transcript))

        #expect(ids.calls == ["call-0", "call-1"])
        #expect(ids.calls.allSatisfy(ids.outputs.contains))
    }

    // MARK: - The claims of the restored session

    @Test("a suspending close of a restored session leaves its open claims open, with no lost terminal")
    func openClaimsStayOpen() async throws {
        let recording = try await ShutdownRecording.make(calling: [Self.openRunOp, Self.openRunOp])
        defer { await recording.end() }
        let answering = try await Self.openTwoRuns(in: recording)
        await Self.suspendAndClose(recording, ending: answering)
        let keys = try await recording.statuses().keys
        let tree = try await Self.restoreClaimingEveryRun(of: recording)
        defer { await SessionFixtureLifecycle.close(tree) }

        tree.root.suspend()
        var accepted: [Bool] = []
        for key in keys {
            accepted.append(await tree.root.completeClaimedRun(key, outcome: .succeeded, detail: nil))
        }
        await tree.root.close()

        #expect(accepted == [false, false])
        #expect(try await recording.statuses().values.map { $0 } == [.orphaned, .orphaned])
    }
}
