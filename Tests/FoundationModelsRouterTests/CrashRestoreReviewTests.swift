import Foundation
import FoundationModels
import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// A recorder that holds the first write after ``arm()`` at a gate.
///
/// The write goes to the base recorder only after ``release`` opens. A test
/// uses it to stop a journal write in the middle, so that it can run a close
/// in that moment, with no sleep and no time limit.
private actor GatedRecorder: TranscriptRecorder {
    /// The recorder that does the real write.
    private let base: JSONLRecorder

    /// Whether the next write waits at the gate.
    private var isArmed = false

    /// Opens when a write reached the gate.
    let entered = RunLatch()

    /// The gate. A write that reached it waits until it opens.
    let release = RunLatch()

    /// Makes a gated recorder.
    ///
    /// - Parameter base: The recorder that does the real write.
    init(base: JSONLRecorder) {
        self.base = base
    }

    /// Holds the next write at the gate.
    func arm() {
        isArmed = true
    }

    func append(_ partial: TranscriptEvent.Partial, to directory: URL?) async {
        if isArmed {
            isArmed = false
            await entered.open()
            await release.waitUntilOpen()
        }
        await base.append(partial, to: directory)
    }
}

/// Exercises the fixes of the independent crash and restore review of the
/// claim API, the write-ahead record and the restore.
///
/// The crash is simulated as the other restore suites do it: the recorded
/// session stays open, a second router over the same recording root restores
/// it, and the test closes both sessions at its end.
@Suite("Crash and restore review fixes")
struct CrashRestoreReviewTests {
    /// The temp directory prefix every fixture of this suite is built with.
    private static let tempDirPrefix = "CrashRestoreReviewTests"

    /// The tool of the run that the tests claim.
    private static let tool = "shell"

    /// The key of the run that the tests claim.
    private static let runKey = RunKey(tool: tool, correlationID: "run-1")

    // MARK: - Fixture

    /// A recorded session with a restore of it.
    private struct Restored {
        /// The restored tree.
        let tree: RestoredSessionTree

        /// The session that the recording belongs to, still open as the
        /// session of a crashed process is.
        let recorded: any RoutedSession

        /// The directory of the recording of the router.
        let routerDirectory: URL

        /// The directories to remove at the end.
        let directories: [URL]

        /// The recorded events of the restored root, in `seq` order.
        func events() throws -> [TranscriptEvent] {
            try TranscriptTree.load(under: routerDirectory).events(forSession: tree.root.id)
        }

        /// The terminal events that the journal holds for `key`.
        func terminals(of key: RunKey) throws -> [OperationEvent] {
            try events().flatMap(\.operationEvents).filter { event in
                event.kind == .completed && RunKey(tool: event.tool, correlationID: event.correlationID) == key
            }
        }

        /// Closes both sessions and removes the directories.
        func end() async {
            await tree.root.close()
            await recorded.close()
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// The router of one test, over a model that answers with text.
    private static func makeRouter(
        id: ULID = .generate(), cacheDir: URL, recordingsDir: URL, recorder: any TranscriptRecorder
    ) -> Router {
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: []), log: ScriptedAnswerLog()))
        return RouterTestFixtures.makeRouter(
            id: id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
    }

    /// Records a root session that journals `journaled` with one answer, and
    /// restores it under a second router over the same recording root.
    ///
    /// - Parameters:
    ///   - journaled: The run events posted before the answer.
    ///   - claiming: The runs that the restore claims.
    ///   - restoreRecorder: Wraps the recorder of the second router, or
    ///     `nil` for the plain recorder.
    /// - Returns: The restore. The caller ends it.
    /// - Throws: What the restore throws, after it closed the recorded
    ///   session and removed the directories.
    private static func recordAndRestore(
        journaled: [OperationEvent], claiming: Set<RunKey>,
        restoreRecorder: (@Sendable (JSONLRecorder) -> any TranscriptRecorder)? = nil
    ) async throws -> Restored {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = JSONLRecorder(directory: recordingsDir)
        let router1 = makeRouter(cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)
        let profile1 = try await router1.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let root = profile1.standard.makeSession()
        do {
            for event in journaled {
                await root.outbox.post(event: event)
            }
            _ = try await root.respond(to: "hello")
            let router2 = makeRouter(
                id: router1.id, cacheDir: cacheDir, recordingsDir: recordingsDir,
                recorder: restoreRecorder?(recorder) ?? recorder)
            let profile2 = try await router2.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            let tree = try await profile2.standard.restoreSessionTree(root: root.id, claimingRuns: claiming)
            return Restored(
                tree: tree, recorded: root,
                routerDirectory: RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir),
                directories: [cacheDir, recordingsDir])
        } catch {
            await root.close()
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
            throw error
        }
    }

    /// A progress event of the run `correlationID` of the tool `tool`.
    private static func progress(tool: String = tool, correlationID: String) -> OperationEvent {
        OperationEvent(tool: tool, op: "run command", correlationID: correlationID, kind: .progress, detail: "working")
    }

    // MARK: - Item 10: completeClaimedRun versus close

    /// Restores a session with a claim on `runKey`, and runs `body` with it
    /// and with the gate that holds the next journal write of the restored
    /// session. The session ends, and the gate opens, also when `body` throws
    /// (rule T1).
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `body` runs there.
    ///   - body: The steps of the test, given the restore, the restored
    ///     session and the gate.
    private static func withGatedClaim(
        isolation: isolated (any Actor)? = #isolation,
        _ body: (Restored, RoutedSessionActor, GatedRecorder) async throws -> Void
    ) async throws {
        let box = ObjectBox<GatedRecorder>()
        let restored = try await recordAndRestore(
            journaled: [progress(correlationID: runKey.correlationID)], claiming: [runKey],
            restoreRecorder: { base in
                let recorder = GatedRecorder(base: base)
                box.value = recorder
                return recorder
            })
        let gate = try #require(box.value)
        defer { await restored.end() }
        defer { await gate.release.open() }
        let session = try #require(restored.tree.root as? RoutedSessionActor)
        try await body(restored, session, gate)
    }

    @Test("the claim stays held while the terminal event of its completion is on its way to the journal")
    @MainActor
    func claimStaysHeldDuringCompletion() async throws {
        try await Self.withGatedClaim { _, session, gate in
            await gate.arm()
            let completion = Task { await session.completeClaimedRun(Self.runKey, outcome: .succeeded, detail: "done") }
            await gate.entered.waitUntilOpen()

            #expect(await session.openClaims.keys.contains(Self.runKey))

            await gate.release.open()
            _ = await completion.value
        }
    }

    @Test("a close during a completion of a claimed run leaves one terminal event in the journal")
    @MainActor
    func closeDuringCompletionLeavesOneTerminal() async throws {
        try await Self.withGatedClaim { restored, session, gate in
            // The completion stops inside its journal write.
            await gate.arm()
            let completion = Task { await session.completeClaimedRun(Self.runKey, outcome: .succeeded, detail: "done") }
            await gate.entered.waitUntilOpen()
            // The open claim is work, so this wait ends only when the close
            // starts. Then the close passed the point where it takes the claims.
            let idleWait = Task { await session.awaitIdle() }
            let closing = Task { await session.close() }
            _ = await idleWait.value
            await gate.release.open()
            _ = await completion.value
            await closing.value

            let terminals = try restored.terminals(of: Self.runKey)
            #expect(terminals.count == 1)
        }
    }

    // MARK: - Fixture of a crash inside a tool call

    /// The SDK id of the scripted call.
    private static let callID = "call-held"

    /// The `value` argument of the scripted call.
    private static let argumentValue = "CRASH-REVIEW-ARGUMENT"

    /// A recorded session that a crash stopped inside a tool call: the
    /// marker of the call is on disk, and the tool body is held.
    private struct HeldCall {
        /// The session, still open and held inside its tool run.
        let session: any RoutedSession

        /// The router of the recording and its resolved profile.
        let router: Router
        let profile: LanguageModelProfile

        /// The folders of the test.
        let directories: TestDirectories

        /// The recorder both routers write through.
        let recorder: JSONLRecorder

        /// The held tool, handed to the restore again.
        let tool: MountFixtures.GatedTool

        /// The latch that holds the tool body.
        let gate: RunLatch

        /// The completion token of the run of the call, as the marker holds it.
        let token: String

        /// The key of the run of the call.
        var key: RunKey { RunKey(tool: tool.name, correlationID: token) }

        /// Starts a session whose first answer calls the held tool, and waits
        /// until the marker of the call is on disk and the tool body holds.
        static func make() async throws -> HeldCall {
            let directories = TestDirectories(prefix: CrashRestoreReviewTests.tempDirPrefix)
            let recorder = JSONLRecorder(directory: directories.recordingsDir)
            let gate = RunLatch()
            let entered = RunLatch()
            let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
            let script = ScriptedAnswerScript(
                rounds: [
                    [ScriptedToolCall(id: callID, toolName: tool.name, argument: .literal(argumentValue))]
                ])
            let container = ScriptedToolCallingContainer(
                model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
            let router = RouterTestFixtures.makeRouter(
                cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir, recorder: recorder,
                loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
            let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directories.cacheDir) {
                try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            }
            let session = profile.standard.makeSession(tools: [tool])
            _ = Task { try await session.respond(to: "run the tool") }
            await entered.waitUntilOpen()
            let routerDirectory = RouterTestFixtures.routerDirectory(
                routerId: router.id, recordingsDir: directories.recordingsDir)
            let events = try TranscriptTree.load(under: routerDirectory).events(forSession: session.id)
            let token = try #require(
                events.first { $0.kind == .toolCallStarted }?.entry?.toolCalls?.first?.correlationID)
            return HeldCall(
                session: session, router: router, profile: profile, directories: directories, recorder: recorder,
                tool: tool, gate: gate, token: token)
        }

        /// Records a sub-agent child of the session that was spawned by the
        /// call of `token`, and closes it, so it is unended on disk.
        ///
        /// - Returns: The session id of the child.
        func recordChild(token: String) async -> ULID {
            let child = profile.standard.makeSession(
                configuration: SessionConfiguration(
                    agentSpawn: SessionRecord.AgentSpawn(parentSessionId: session.id, parentToolCallId: token)))
            await child.close()
            return child.id
        }

        /// Restores the tree of the session under a second router over the
        /// same recording root: the fresh process after a crash.
        func restore(claiming: Set<RunKey> = []) async throws -> RestoredSessionTree {
            let container = ScriptedToolCallingContainer(
                model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: []), log: ScriptedAnswerLog()))
            let restoring = RouterTestFixtures.makeRouter(
                id: router.id, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir,
                recorder: recorder,
                loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
            let restoringProfile = try await restoring.resolve(
                profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return try await restoringProfile.standard.restoreSessionTree(
                root: session.id, tools: [tool], claimingRuns: claiming)
        }

        /// Opens the gate, closes the session and removes the folders.
        func end() async {
            await gate.open()
            await session.close()
            directories.remove()
        }
    }

    // MARK: - Item 11: a run with no event is claimable

    @Test("a crash before the first event leaves a claimable run when an unended child holds its token")
    @MainActor
    func eventlessRunWithUnendedChildIsClaimable() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        _ = await crash.recordChild(token: crash.token)

        let tree = try await crash.restore(claiming: [crash.key])
        defer { await tree.root.close() }

        let session = try #require(tree.root as? RoutedSessionActor)
        #expect(await session.openClaims.keys.contains(crash.key))
    }

    @Test("a claimed run with no event gets the running output")
    @MainActor
    func eventlessClaimedRunGetsTheRunningOutput() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        _ = await crash.recordChild(token: crash.token)

        let tree = try await crash.restore(claiming: [crash.key])
        defer { await tree.root.close() }

        #expect(ScriptedToolCallingModel.Executor.toolOutputTexts(in: await tree.root.transcript) == [OpenToolCalls.runningOutput])
    }

    @Test("the host completes a claimed run that wrote no event")
    @MainActor
    func eventlessClaimedRunCompletes() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        _ = await crash.recordChild(token: crash.token)
        let tree = try await crash.restore(claiming: [crash.key])
        defer { await tree.root.close() }

        let accepted = await tree.root.completeClaimedRun(crash.key, outcome: .succeeded, detail: "done")

        #expect(accepted)
    }

    @Test("a run with no event and no child is not claimable")
    @MainActor
    func eventlessRunWithoutChildThrows() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }

        await #expect(throws: SessionTreeRestorationError.runNotClaimable(crash.key)) {
            _ = try await crash.restore(claiming: [crash.key])
        }
    }

    @Test("a run with no event is not claimable when the child is ended")
    @MainActor
    func eventlessRunWithEndedChildThrows() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        let child = await crash.recordChild(token: crash.token)
        let root = crash.session.recordingDirectory.deletingLastPathComponent()
        await crash.router.sessionDirectory.useRecordingRoots { [root] }
        _ = try await crash.router.sessionDirectory.markEnded(child, reason: .finished)

        await #expect(throws: SessionTreeRestorationError.runNotClaimable(crash.key)) {
            _ = try await crash.restore(claiming: [crash.key])
        }
    }

    // MARK: - Item 12: honest placeholder texts

    @Test("a claimed orphan run gets the running output")
    @MainActor
    func claimedOrphanGetsTheRunningOutput() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        await crash.session.outbox.journalWithoutStaging(
            event: OperationEvent(
                tool: crash.tool.name, op: "run tool", correlationID: crash.token, kind: .progress, detail: "working"))

        let tree = try await crash.restore(claiming: [crash.key])
        defer { await tree.root.close() }

        #expect(ScriptedToolCallingModel.Executor.toolOutputTexts(in: await tree.root.transcript) == [OpenToolCalls.runningOutput])
        #expect(OpenToolCalls.runningOutput.contains("still working"))
        #expect(OpenToolCalls.runningOutput.contains("as a message"))
    }

    @Test("an orphan run that nobody claimed gets the lost output")
    @MainActor
    func unclaimedOrphanGetsTheLostOutput() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        await crash.session.outbox.journalWithoutStaging(
            event: OperationEvent(
                tool: crash.tool.name, op: "run tool", correlationID: crash.token, kind: .progress, detail: "working"))

        let tree = try await crash.restore()
        defer { await tree.root.close() }

        #expect(ScriptedToolCallingModel.Executor.toolOutputTexts(in: await tree.root.transcript) == [OpenToolCalls.lostOutput])
        #expect(OpenToolCalls.lostOutput.contains("was lost"))
        #expect(!OpenToolCalls.lostOutput.contains("still working"))
    }

    @Test("a call with no run gets the unrecorded output")
    @MainActor
    func callWithoutARunGetsTheUnrecordedOutput() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }

        let tree = try await crash.restore()
        defer { await tree.root.close() }

        #expect(ScriptedToolCallingModel.Executor.toolOutputTexts(in: await tree.root.transcript) == [OpenToolCalls.unrecordedOutput])
        #expect(OpenToolCalls.unrecordedOutput.contains("not recorded"))
        #expect(OpenToolCalls.unrecordedOutput.contains("may or may not"))
        #expect(OpenToolCalls.unrecordedOutput.contains("not safe to repeat"))
        #expect(!OpenToolCalls.unrecordedOutput.contains("again"))
    }

    // MARK: - Item 13: no double records after a restore

    @Test("the next submission after a restore records no folded placeholder entry")
    @MainActor
    func nextSubmissionRecordsNoFoldedEntry() async throws {
        let crash = try await HeldCall.make()
        defer { await crash.end() }
        let tree = try await crash.restore()
        defer { await tree.root.close() }

        _ = try await tree.root.respond(to: "after the restore")

        let routerDirectory = RouterTestFixtures.routerDirectory(
            routerId: crash.router.id, recordingsDir: crash.directories.recordingsDir)
        let events = try TranscriptTree.load(under: routerDirectory).events(forSession: tree.root.id)
        let foldedCalls = events.filter { $0.entry?.entryId.hasPrefix("open-calls-") == true }
        let placeholders = events.filter { event in
            event.kind == .toolOutput && event.entry?.entryId == Self.callID
        }
        #expect(foldedCalls.isEmpty)
        #expect(placeholders.isEmpty)
    }

    @Test("a real output of a started call that has no .toolCalls entry gives one output, not two")
    func realOutputOfAStartedCallGivesOneOutput() throws {
        let routerID = ULID.generate()
        let sessionID = ULID.generate()
        let call = ToolCallPayload(id: Self.callID, toolName: Self.tool, argumentsJSON: "{}", correlationID: "token")
        let marker = TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: 1, ts: Date(timeIntervalSince1970: 1),
            kind: .toolCallStarted, entry: TranscriptEntryPayload(entryId: "started-" + Self.callID, toolCalls: [call]))
        let output = TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: 2, ts: Date(timeIntervalSince1970: 2),
            kind: .toolOutput, text: "real output",
            entry: TranscriptEntryPayload(
                entryId: Self.callID, segments: [.text(id: "real-text", content: "real output")], toolName: Self.tool))

        let transcript = try ContextRenderer.context(of: [marker, output])

        #expect(TranscriptEntrySegments.toolOutputIDs(in: transcript) == [Self.callID])
    }

    // MARK: - Item 14: a failed marker write is visible

    /// The error that a failing line append throws.
    private struct MarkerWriteFailure: Error {}

    /// The write-ahead marker of the call `callID`, as a partial event.
    private static func markerPartial(callID: String) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: ULID.generate(), sessionId: ULID.generate(), kind: .toolCallStarted,
            entry: TranscriptEntryPayload(
                entryId: "started-" + callID,
                toolCalls: [ToolCallPayload(id: callID, toolName: tool, argumentsJSON: "{}", correlationID: "token")]))
    }

    /// Asserts that the capture holds the log of a dropped marker with the id
    /// of its call, and that the counter counted the loss once.
    private static func expectMarkerDropped(in context: TelemetryCapture.Context) throws {
        context.expectLogged(
            containing: "tool call marker", metadata: [RouterTelemetry.LogMetadataKey.toolCallId: callID])
        let counter = try context.metricsFactory.expectCounter(RouterTelemetry.MetricName.toolCallMarkerDropped, [])
        #expect(counter.totalValue == 1)
    }

    @Test("a marker write that fails is logged with the call id and counted")
    func failedMarkerWriteIsLoggedAndCounted() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = JSONLRecorder(directory: directory, appendLine: { _, _ in throw MarkerWriteFailure() })

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await recorder.append(Self.markerPartial(callID: Self.callID), to: nil)
            return context
        }

        try Self.expectMarkerDropped(in: context)
    }

    @Test("a marker that the recording root refuses is logged with the call id and counted")
    func refusedMarkerIsLoggedAndCounted() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try JSONLRecorder(owningDirectory: directory)
        let refused = JSONLRecorder(directory: directory)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await refused.append(Self.markerPartial(callID: Self.callID), to: nil)
            return context
        }
        withExtendedLifetime(owner) {}

        try Self.expectMarkerDropped(in: context)
    }

    @Test("an event that is not a marker and fails to write is not counted as a lost marker")
    func failedOtherWriteIsNotCountedAsAMarker() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = JSONLRecorder(directory: directory, appendLine: { _, _ in throw MarkerWriteFailure() })
        let other = TranscriptEvent.Partial(
            routerId: ULID.generate(), sessionId: ULID.generate(), kind: .session)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await recorder.append(other, to: nil)
            return context
        }

        #expect(
            !context.metricRecords.contains { $0.label == RouterTelemetry.MetricName.toolCallMarkerDropped })
    }

    /// A recorder that fails the write of each marker and writes the rest.
    private static func recorderFailingMarkers(in directory: URL) -> JSONLRecorder {
        JSONLRecorder(
            directory: directory,
            appendLine: { record, file in
                if let event = record as? TranscriptEvent, event.kind == .toolCallStarted {
                    throw MarkerWriteFailure()
                }
                try JSONLAppend.toDisk(record, file)
            })
    }

    @Test("a tool still runs when the marker write of its call fails")
    @MainActor
    func toolRunsWhenTheMarkerWriteFails() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let recorder = Self.recorderFailingMarkers(in: directories.recordingsDir)
        let script = ScriptedAnswerScript(
            rounds: [
                [ScriptedToolCall(id: Self.callID, toolName: MountFixtures.FastTool().name, argument: .literal(Self.argumentValue))]
            ])
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(tools: [MountFixtures.FastTool()])
        defer { await session.close() }

        _ = try await session.respond(to: "run the tool")

        let outputs = ScriptedToolCallingModel.Executor.toolOutputTexts(in: await session.transcript)
        #expect(outputs.count == 1)
    }
}

/// A box that a `@Sendable` closure of a test writes to, and the test reads
/// after the closure ran.
// swiftlint:disable:next no_unchecked_sendable  value is written once by the closure inside recordAndRestore, which the test awaits, and read only after that await returned
private final class ObjectBox<Value: Sendable>: @unchecked Sendable {
    /// The value, or `nil` before the closure ran.
    var value: Value?
}
