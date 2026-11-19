import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing

@testable import FoundationModelsRouter

/// Exercises the restore of a recorded session onto another model of the same
/// profile: ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``
/// with `switchingModel` set.
///
/// A host that changes the model of a session suspends the old session and
/// restores the same id on the handle of the new slot. These tests hold what
/// must stay (the id, the folder, the lineage, the history) and what must
/// change (the recorded model, the slot, and the next submission).
@Suite("A restore onto another model keeps the session")
struct ModelSwitchRestoreTests {
    // MARK: - Constants

    /// The prompt of the first answer, on the old model.
    private static let firstPrompt = "first question"

    /// The prompt of the answer after the switch, on the new model.
    private static let secondPrompt = "second question"

    /// The name of the tool that saves its context.
    private static let toolName = "record_context"

    /// The model of the slot the session is recorded on.
    private static let oldModel: ModelRef = "org/std-a"

    /// The model of the slot the session is restored onto.
    private static let newModel: ModelRef = "org/flash-a"

    /// The context that the `index.md` of a recorded fork records before
    /// the switch. It differs from the context of each handle of the
    /// profile.
    private static let recordedForkContext = 4096

    /// The model of the standard slot of the other profile.
    private static let otherModel: ModelRef = "org/std-b"

    /// A profile whose standard slot resolves to ``otherModel``.
    private static let otherDefinition = ProfileDefinition(
        name: "coding-other",
        description: "a profile whose standard model differs from the recorded one",
        standard: ["org/std-b"],
        flash: ["org/flash-a"],
        embedding: ["org/emb-a"],
        decision: ["org/flash-a"],
        context: ScriptedSessionContext.tokens
    )

    // MARK: - Fixtures

    /// The routers and the folders of one test.
    private struct Workspace {
        let directories: TestDirectories
        let router: Router
        let profile: LanguageModelProfile
        let tracer: InMemoryTracer
        let store = ContextStore()

        /// The recording root of the router.
        var routerDirectory: URL {
            RouterTestFixtures.routerDirectory(routerId: router.id, recordingsDir: directories.recordingsDir)
        }

        /// The session directory of the router.
        var sessionDirectory: RouterSessionDirectory {
            get throws { try #require(profile.standard.sessionDirectory) }
        }

        /// The tree that the recording root holds now.
        func loadTree() throws -> TranscriptTree {
            try TranscriptTree.load(under: routerDirectory)
        }

        /// The folder of the recorded session `id`.
        func folder(of id: ULID) throws -> URL {
            try #require(try TranscriptTree.sessionFolder(of: id, under: routerDirectory))
        }

        /// Records one answer on the standard slot, then suspends the session
        /// as a host does before it restores the id onto another model. The
        /// old session object stays alive.
        func recordAndSuspend() async throws -> any RoutedSession {
            let old = profile.standard.makeSession(configuration: SessionConfiguration())
            _ = try await old.respond(to: ModelSwitchRestoreTests.firstPrompt)
            old.suspend()
            return old
        }

        /// Restores `id` onto the flash slot with the switch allowed.
        func switchToFlash(_ id: ULID) async throws -> RestoredSession {
            try await profile.flash.restoreSession(
                id: id,
                tools: [ContextRecordingTool(name: ModelSwitchRestoreTests.toolName, store: store)],
                switchingModel: true)
        }

        /// Resolves the other profile on a second router over the same
        /// recording root, as a new process does.
        func resolveOtherProfile() async throws -> (router: Router, profile: LanguageModelProfile) {
            let other = RouterTestFixtures.makeRouter(
                id: router.id, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir,
                recorder: JSONLRecorder(directory: directories.recordingsDir),
                loader: StubModelLoader(
                    container: ToolDrivingLLMContainer(), dimension: RouterTestFixtures.stubDimension))
            let profile = try await other.resolve(
                profile: ModelSwitchRestoreTests.otherDefinition, reporting: ResolutionProgress())
            return (other, profile)
        }

        /// The `modelChanged` events of the session `id` itself. The
        /// effective events of a fork also hold events of its source after
        /// the cut, such as the `modelChanged` event of a moved source, so
        /// the filter keeps the events with the id of the session alone.
        func modelChangedEvents(of id: ULID) throws -> [TranscriptEvent] {
            try loadTree().effectiveEntryEvents(forSession: id, alongWith: [.modelChanged])
                .filter { $0.kind == .modelChanged && $0.sessionId == id }
        }
    }

    /// Runs `body` with a profile over a durable recording root.
    private static func withWorkspace(_ body: (Workspace) async throws -> Void) async throws {
        let directories = TestDirectories(prefix: "ModelSwitchRestoreTests")
        defer { directories.remove() }
        let tracer = InMemoryTracer()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir,
            recorder: JSONLRecorder(directory: directories.recordingsDir),
            loader: StubModelLoader(container: ToolDrivingLLMContainer(), dimension: RouterTestFixtures.stubDimension),
            tracer: tracer)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        try await body(Workspace(directories: directories, router: router, profile: profile, tracer: tracer))
    }

    // MARK: - What stays

    /// The production change that makes this test fail: a switch that gives
    /// the restored session a new id.
    @Test("the restored session has the id of the old session")
    func theIdStaysTheSame() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            await restored.session.close()

            #expect(restored.session.id == old.id)
        }
    }

    /// The production change that makes this test fail: a switch that writes
    /// the session in a new folder.
    @Test("a session that switched models has one folder only")
    func theSessionHasOneFolder() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            _ = try await restored.session.respond(to: Self.secondPrompt)
            await restored.session.close()

            #expect(try workspace.loadTree().roots.map(\.id) == [old.id])
        }
    }

    /// The production change that makes this test fail: a switch that ends
    /// the old session.
    @Test("a switch writes no ended marker")
    func theSwitchWritesNoEndedMarker() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)

            let marker = try await workspace.sessionDirectory.endMarker(of: old.id)
            await restored.session.close()

            #expect(marker == nil)
        }
    }

    /// The production change that makes this test fail: a switch that drops
    /// the transcript of the old model from the read by id.
    @Test("a read of the transcript by the id returns the whole history")
    func theTranscriptHoldsTheWholeHistory() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            _ = try await restored.session.respond(to: Self.secondPrompt)
            await restored.session.close()

            let transcript = try workspace.loadTree().effectiveTranscript(forSession: old.id, view: .fullHistory)
            #expect(transcript.promptTexts == [Self.firstPrompt, Self.secondPrompt])
        }
    }

    /// The production change that makes this test fail: a switch that gives
    /// the tools of the restored session another session id.
    @Test("the tools of the restored session see the id of the old session")
    func theToolsSeeTheOldId() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            _ = try await restored.session.respond(to: Self.secondPrompt)
            await restored.session.close()

            #expect(workspace.store.context(of: old.id)?.sessionID == old.id)
        }
    }

    // MARK: - What changes

    /// The production change that makes this test fail: a switch that
    /// appends no `modelChanged` event.
    @Test("a switch appends one modelChanged event to the transcript")
    func theSwitchAppendsOneEvent() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            await restored.session.close()

            #expect(try workspace.modelChangedEvents(of: old.id).count == 1)
        }
    }

    /// The production change that makes this test fail: an event that is
    /// stamped with the old model.
    @Test("the modelChanged event is stamped with the new model and slot")
    func theEventIsStampedWithTheNewModel() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            await restored.session.close()

            let event = try #require(try workspace.modelChangedEvents(of: old.id).first)
            #expect(event.model == Self.newModel && event.slot == .flash)
        }
    }

    /// The production change that makes this test fail: an event that does
    /// not name the old model.
    @Test("the text of the modelChanged event names the old model")
    func theEventNamesTheOldModel() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            await restored.session.close()

            let event = try #require(try workspace.modelChangedEvents(of: old.id).first)
            #expect(try #require(event.text).contains(Self.oldModel.stringValue))
        }
    }

    /// The production change that makes this test fail: a switch that leaves
    /// the old model in `index.md`.
    @Test("the index.md records the new model and slot")
    func theIndexRecordsTheNewModel() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            await restored.session.close()

            let record = try #require(try SessionIndexFile.read(in: workspace.folder(of: old.id)))
            #expect(record.model == Self.newModel && record.slot == .flash)
        }
    }

    /// The production change that makes this test fail: a switch that keeps
    /// the model of the old record for the next submission.
    @Test("the next submission records the new model.ref")
    func theNextSubmissionRecordsTheNewModel() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.switchToFlash(old.id)
            _ = try await restored.session.respond(to: Self.secondPrompt)
            await restored.session.close()

            let last = try #require(workspace.tracer.finishedSubmissionSpans.last)
            #expect(last.attributes.get(RouterTelemetry.AttributeKey.modelRef) == .string(Self.newModel.stringValue))
        }
    }

    // MARK: - What is refused or ignored

    /// The production change that makes this test fail: a restore that
    /// accepts another model with no switch.
    @Test("a restore onto another model with no switch still throws modelMismatch")
    func noSwitchStillThrowsModelMismatch() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let other = try await workspace.resolveOtherProfile()
            defer { withExtendedLifetime(other.router) {} }

            await #expect(
                throws: SessionTreeRestorationError.modelMismatch(
                    session: old.id, slot: .standard, recorded: Self.oldModel, resident: Self.otherModel)
            ) {
                _ = try await other.profile.standard.restoreSession(id: old.id)
            }
        }
    }

    /// The production change that makes this test fail: a switch that
    /// refuses a model of the same slot because its model differs.
    @Test("a switch restores onto a model of the same slot in another profile")
    func aSwitchWorksInTheSameSlot() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let other = try await workspace.resolveOtherProfile()
            defer { withExtendedLifetime(other.router) {} }
            let restored = try await other.profile.standard.restoreSession(id: old.id, switchingModel: true)
            await restored.session.close()

            let record = try #require(try SessionIndexFile.read(in: workspace.folder(of: old.id)))
            #expect(record.model == Self.otherModel && record.slot == .standard)
        }
    }

    /// The production change that makes this test fail: a switch to the model
    /// the session already runs on that still writes an event.
    @Test("a switch onto the recorded model writes no modelChanged event")
    func aSwitchToTheSameModelWritesNothing() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            let restored = try await workspace.profile.standard.restoreSession(id: old.id, switchingModel: true)
            await restored.session.close()

            #expect(try workspace.modelChangedEvents(of: old.id).isEmpty)
        }
    }

    // MARK: - Forks

    /// Records one answer, suspends the session, and writes a recorded fork
    /// of it with no session. Then restores the source onto the flash slot
    /// with the switch allowed, closes the restored session, and reads the
    /// `index.md` of the fork. The `index.md` of the fork records
    /// ``recordedForkContext`` before the switch, so a move that writes the
    /// context of the new handle shows in it.
    ///
    /// - Parameter workspace: The workspace of the test.
    /// - Returns: The id of the fork and the record that its `index.md`
    ///   holds after the switch.
    /// - Throws: What the answer, the reads, the writes and the restore throw.
    private static func recordedForkAfterRootMove(
        in workspace: Workspace
    ) async throws -> (forkID: ULID, recordAfter: SessionRecord) {
        let source = try await workspace.recordAndSuspend()
        let cut = try RecordedForkFixtures.cut(atEndOf: source.id, under: workspace.routerDirectory)
        let forkID = ULID.generate()
        let forkFolder = try RecordedForkFixtures.writeFork(
            id: forkID, under: try workspace.folder(of: source.id), cut: cut)
        var record = try #require(try SessionIndexFile.read(in: forkFolder))
        record.context = Self.recordedForkContext
        try SessionIndexFile.save(record, in: forkFolder)
        let restored = try await workspace.switchToFlash(source.id)
        await restored.session.close()
        let recordAfter = try #require(try SessionIndexFile.read(in: forkFolder))
        return (forkID, recordAfter)
    }

    /// The production change that makes this test fail: a switch that moves
    /// the root and leaves a recorded fork on the old model, so the fork
    /// throws modelMismatch.
    @Test("a recorded fork of the session moves to the new model with its root")
    func aForkMovesWithTheRoot() async throws {
        try await Self.withWorkspace { workspace in
            let (_, record) = try await Self.recordedForkAfterRootMove(in: workspace)

            #expect(record.model == Self.newModel)
        }
    }

    /// The production change that makes this test fail: a move of a recorded
    /// fork that writes no `modelChanged` event, or more than one.
    @Test("a recorded fork that moves with its root gets one modelChanged event")
    func aMovedForkGetsOneEvent() async throws {
        try await Self.withWorkspace { workspace in
            let (forkID, _) = try await Self.recordedForkAfterRootMove(in: workspace)

            #expect(try workspace.modelChangedEvents(of: forkID).count == 1)
        }
    }

    /// The production change that makes this test fail: a move of a recorded
    /// fork whose event is stamped with the old model or the old slot.
    @Test("the modelChanged event of a moved fork is stamped with the new model and slot")
    func theEventOfAMovedForkIsStampedWithTheNewModel() async throws {
        try await Self.withWorkspace { workspace in
            let (forkID, _) = try await Self.recordedForkAfterRootMove(in: workspace)

            let event = try #require(try workspace.modelChangedEvents(of: forkID).first)
            #expect(event.model == Self.newModel && event.slot == .flash)
        }
    }

    /// The production change that makes this test fail: a move of a recorded
    /// fork that leaves the old slot in its `index.md`.
    @Test("the index.md of a moved fork records the new slot")
    func theIndexOfAMovedForkRecordsTheNewSlot() async throws {
        try await Self.withWorkspace { workspace in
            let (_, record) = try await Self.recordedForkAfterRootMove(in: workspace)

            #expect(record.slot == .flash)
        }
    }

    /// The production change that makes this test fail: a move of a recorded
    /// fork that leaves the recorded context in its `index.md`.
    @Test("the index.md of a moved fork records the context of the new handle")
    func theIndexOfAMovedForkRecordsTheNewContext() async throws {
        try await Self.withWorkspace { workspace in
            let (_, record) = try await Self.recordedForkAfterRootMove(in: workspace)

            #expect(record.context == workspace.profile.flash.resolution.contextTokens)
        }
    }

    /// Records one answer, forks the session through the session directory,
    /// and suspends the source as a host does before a switch. The fork
    /// stays live, or the host suspends it too.
    ///
    /// - Parameters:
    ///   - workspace: The workspace of the test.
    ///   - suspendsFork: `true` to suspend the fork too.
    /// - Returns: The suspended source and the fork.
    /// - Throws: What the answer and the fork throw.
    private static func suspendedSourceWithAForkSession(
        in workspace: Workspace, suspendsFork: Bool
    ) async throws -> (source: any RoutedSession, fork: any RoutedSession) {
        let directory = try workspace.sessionDirectory
        let source = workspace.profile.standard.makeSession(configuration: SessionConfiguration())
        _ = try await source.respond(to: Self.firstPrompt)
        let summary = try await directory.fork(
            SessionForkRequest(
                sourceID: source.id, cut: .lastCompletedTurn, forker: .user(clientID: "model-switch-client")))
        let fork = try #require(directory.session(id: summary.id))
        source.suspend()
        if suspendsFork {
            fork.suspend()
        }
        return (source, fork)
    }

    /// Records one answer, forks the session through the session directory,
    /// and suspends the source. Then reads the `index.md` of the fork,
    /// restores the source onto the flash slot with the switch allowed,
    /// closes the restored session and the fork, and reads the `index.md` of
    /// the fork again.
    ///
    /// - Parameters:
    ///   - workspace: The workspace of the test.
    ///   - suspendsFork: `true` to suspend the fork too before the switch.
    /// - Returns: The fork, and the records that its `index.md` holds before
    ///   and after the switch.
    /// - Throws: What the answer, the fork, the reads and the restore throw.
    private static func forkSessionAfterRootMove(
        in workspace: Workspace, suspendsFork: Bool
    ) async throws -> (fork: any RoutedSession, recordBefore: SessionRecord, recordAfter: SessionRecord) {
        let (source, fork) = try await Self.suspendedSourceWithAForkSession(
            in: workspace, suspendsFork: suspendsFork)
        let folder = try workspace.folder(of: fork.id)
        let recordBefore = try #require(try SessionIndexFile.read(in: folder))
        let restored = try await workspace.switchToFlash(source.id)
        await SessionFixtureLifecycle.close([restored.session, fork])
        let recordAfter = try #require(try SessionIndexFile.read(in: folder))
        return (fork, recordBefore, recordAfter)
    }

    /// The production change that makes this test fail: a switch that moves
    /// a fork that has a session in the session directory, live or
    /// suspended. Its session owns its `index.md`, and a later write of that
    /// session puts the old model back.
    @Test("a fork with a session keeps its model when its root moves", arguments: [false, true])
    func aForkWithASessionKeepsItsModel(suspendsFork: Bool) async throws {
        try await Self.withWorkspace { workspace in
            let (_, _, record) = try await Self.forkSessionAfterRootMove(
                in: workspace, suspendsFork: suspendsFork)

            #expect(record.model == Self.oldModel)
        }
    }

    /// The production change that makes this test fail: a switch that writes
    /// the slot or the context of the new handle into the `index.md` of a
    /// fork that has a session.
    @Test("a fork with a session keeps its slot and context when its root moves", arguments: [false, true])
    func aForkWithASessionKeepsItsSlotAndContext(suspendsFork: Bool) async throws {
        try await Self.withWorkspace { workspace in
            let (_, before, after) = try await Self.forkSessionAfterRootMove(
                in: workspace, suspendsFork: suspendsFork)

            #expect(after.slot == before.slot && after.context == before.context)
        }
    }

    /// The production change that makes this test fail: a switch that writes
    /// a `modelChanged` event for a fork that has a session.
    @Test("a fork with a session gets no modelChanged event when its root moves", arguments: [false, true])
    func aForkWithASessionGetsNoEvent(suspendsFork: Bool) async throws {
        try await Self.withWorkspace { workspace in
            let (fork, _, _) = try await Self.forkSessionAfterRootMove(
                in: workspace, suspendsFork: suspendsFork)

            #expect(try workspace.modelChangedEvents(of: fork.id).isEmpty)
        }
    }

    /// The production change that makes this test fail: a switch that
    /// registers a second instance of a suspended fork in the session
    /// directory, in place of the fork object that the host holds.
    @Test("a suspended fork of the session keeps its directory entry when its root moves")
    func aSuspendedForkKeepsItsDirectoryEntry() async throws {
        try await Self.withWorkspace { workspace in
            let (source, fork) = try await Self.suspendedSourceWithAForkSession(in: workspace, suspendsFork: true)

            let restored = try await workspace.switchToFlash(source.id)

            #expect(try workspace.sessionDirectory.session(id: fork.id) as AnyObject? === fork as AnyObject)
            await restored.session.close()
        }
    }

    // MARK: - The directory of the process

    /// The production change that makes this test fail: a registration that
    /// keeps the suspended mark of the old session, so the directory refuses
    /// the ended marker of the restored session.
    @Test("a restore after suspendLiveSessions leaves the restored session not suspended in the directory")
    func theRestoredSessionIsNotSuspended() async throws {
        try await Self.withWorkspace { workspace in
            let directory = try workspace.sessionDirectory
            let old = workspace.profile.standard.makeSession(configuration: SessionConfiguration())
            _ = try await old.respond(to: Self.firstPrompt)
            directory.suspendLiveSessions()
            let restored = try await workspace.switchToFlash(old.id)

            await #expect(throws: Never.self) {
                try await directory.markEnded(old.id, reason: .finished)
            }
            await restored.session.close()
        }
    }

    /// The restore of the same id after the host closed the suspended session.
    @Test("a restore after the host closed the suspended session finds the restored session in the directory")
    func aRestoreAfterCloseRegisters() async throws {
        try await Self.withWorkspace { workspace in
            let old = try await workspace.recordAndSuspend()
            await old.close()
            let restored = try await workspace.switchToFlash(old.id)

            let live = try workspace.sessionDirectory.session(id: old.id)
            #expect(live?.isSuspended == false)
            await restored.session.close()
        }
    }
}
