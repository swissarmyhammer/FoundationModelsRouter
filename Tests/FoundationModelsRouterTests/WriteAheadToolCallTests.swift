import Foundation
import FoundationModels
import Synchronization
import Testing

@testable import FoundationModelsExtras
@testable import FoundationModelsRouter

/// Exercises the write-ahead record of a tool call.
///
/// The `.toolCalls` entry of a submission reaches the recording at the end of
/// the submission. A crash in a tool run thus left no record of the call.
/// Now the session writes one ``TranscriptEvent/Kind/toolCallStarted`` marker
/// when the call starts, before the tool body runs. The `.toolCalls` entry
/// stays as before. A restore drops a marker that a later `.toolCalls` entry
/// covers. It folds the markers that no entry covers into one `.toolCalls`
/// entry with a placeholder `.toolOutput` for each call, so the transcript is
/// valid for the model (``OpenToolCalls``).
///
/// The crash is simulated as the other restore suites do it: the recorded
/// session stays open and held inside its tool run, a second router over the
/// same recording root restores it, and the held run ends only at the end of
/// the test.
@Suite("Write-ahead record of a tool call")
struct WriteAheadToolCallTests {
    /// The temp directory prefix every fixture of this suite is built with.
    private static let tempDirPrefix = "WriteAheadToolCallTests"

    /// The SDK id of the first scripted call.
    private static let firstCallID = "call-first"

    /// The SDK id of the second scripted call.
    private static let secondCallID = "call-second"

    /// The `value` argument of each scripted call.
    private static let argumentValue = "WRITE-AHEAD-ARGUMENT"

    /// The prompt of each scripted answer.
    private static let prompt = "run the tools"

    // MARK: - Fixture

    /// A recorded session over a scripted model, with the recording on disk.
    /// The suite of the write-ahead prompt shares it (``PromptWriteAheadTests``).
    struct Fixture {
        /// The session and the router that keeps its model resident.
        let started: SessionFixtureLifecycle.Started

        /// The durable root of the recording.
        let recordingsDir: URL

        /// The recorder both routers write through.
        let recorder: JSONLRecorder

        /// The tools the session was made with, handed to the restore again.
        let tools: [any Tool]

        /// The latches that hold a tool run. The end of the fixture opens them,
        /// so no run stays held when a check throws.
        let gates: [RunLatch]

        /// The directory of the recording of the router.
        var routerDirectory: URL {
            RouterTestFixtures.routerDirectory(routerId: started.router.id, recordingsDir: recordingsDir)
        }

        /// The recorded events of the session, in `seq` order.
        func events() throws -> [TranscriptEvent] {
            try TranscriptTree.load(under: routerDirectory).events(forSession: started.session.id)
        }

        /// Makes a fixture over `container`.
        ///
        /// - Parameters:
        ///   - container: The container that vends the backend.
        ///   - tools: The tools of the session.
        ///   - gates: The latches that hold a tool run of the session.
        static func make(
            over container: any LoadedLLMContainer, tools: [any Tool], gates: [RunLatch] = []
        ) async throws -> Fixture {
            let recordingsDir = RouterTestFixtures.makeTempDir(prefix: WriteAheadToolCallTests.tempDirPrefix)
            let recorder = JSONLRecorder(directory: recordingsDir)
            let directory = RouterTestFixtures.makeTempDir(prefix: WriteAheadToolCallTests.tempDirPrefix)
            let router = RouterTestFixtures.makeRouter(
                cacheDir: directory, recordingsDir: recordingsDir, recorder: recorder,
                loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
            let profile = try await RouterTestFixtures.removingDirectoryOnThrow(directory) {
                try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            }
            let session = profile.standard.makeSession(tools: tools)
            return Fixture(
                started: SessionFixtureLifecycle.Started(session: session, router: router, directory: directory),
                recordingsDir: recordingsDir, recorder: recorder, tools: tools, gates: gates)
        }

        /// Restores the recorded session under a second router over the same
        /// recording root: the fresh process after a crash.
        func restore() async throws -> RestoredSession {
            let container = ScriptedToolCallingContainer(
                model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: []), log: ScriptedAnswerLog()))
            let router = RouterTestFixtures.makeRouter(
                id: started.router.id, cacheDir: started.directory, recordingsDir: recordingsDir, recorder: recorder,
                loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
            let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
            return try await profile.standard.restoreSession(id: started.session.id, tools: tools)
        }

        /// Ends the fixture: opens the gates, closes the session and removes
        /// both directories.
        func end() async {
            for gate in gates {
                await gate.open()
            }
            await started.session.close()
            try? FileManager.default.removeItem(at: started.directory)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
    }

    /// A scripted container whose model plays `rounds`, one call in each.
    static func container(calling toolName: String, in callIDs: [String]) -> ScriptedToolCallingContainer {
        let script = ScriptedAnswerScript(
            rounds: callIDs.map { id in
                [ScriptedToolCall(id: id, toolName: toolName, argument: .literal(argumentValue))]
            })
        return ScriptedToolCallingContainer(model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
    }

    /// The SDK call ids that the `.toolCalls` entries of `entries` hold, one
    /// array for each entry.
    private static func toolCallIDs(in entries: [Transcript.Entry]) -> [[String]] {
        entries.compactMap { entry in
            guard case .toolCalls(let calls) = entry else { return nil }
            return calls.map(\.id)
        }
    }

    /// The text of the `.toolOutput` entries of `entries`, in order.
    private static func toolOutputTexts(in entries: [Transcript.Entry]) -> [String] {
        entries.compactMap { entry in
            guard case .toolOutput(let output) = entry else { return nil }
            return output.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }

    // MARK: - A crash in a tool run

    @Test("the marker of a call is on disk while the tool body still runs")
    @MainActor
    func markerIsOnDiskWhileTheToolRuns() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let markers = try fixture.events().filter { $0.kind == .toolCallStarted }.compactMap(\.entry?.toolCalls)

        #expect(markers.map { $0.map(\.id) } == [[Self.firstCallID]])
    }

    @Test("the marker carries the tool name and the arguments of the call")
    @MainActor
    func markerCarriesNameAndArguments() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let call = try #require(
            fixture.events().first { $0.kind == .toolCallStarted }?.entry?.toolCalls?.first)

        #expect(call.toolName == tool.name)
        #expect(call.argumentsJSON.contains(Self.argumentValue))
    }

    @Test("a restore after the crash folds the open call into one .toolCalls entry")
    @MainActor
    func restoreFoldsTheOpenCall() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let restored = try await fixture.restore()
        defer { await restored.session.close() }
        let entries = Array(await restored.session.transcript)

        #expect(Self.toolCallIDs(in: entries) == [[Self.firstCallID]])
    }

    @Test("a restore after the crash answers a call that has no run in the journal with the unrecorded output")
    @MainActor
    func restoreAnswersTheOpenCallWithThePlaceholder() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let restored = try await fixture.restore()
        defer { await restored.session.close() }
        let entries = Array(await restored.session.transcript)

        #expect(TranscriptEntrySegments.toolOutputIDs(in: entries) == [Self.firstCallID])
        #expect(Self.toolOutputTexts(in: entries) == [OpenToolCalls.unrecordedOutput])
    }

    // MARK: - The placeholder follows the run in the journal

    /// The completion token of the run of the hand-built calls.
    private static let runToken = "run-token-1"

    @Test("a call whose run is orphaned in the journal and claimed gets the running output")
    func claimedOrphanedRunGetsTheRunningOutput() {
        let events = [
            Self.markerEvent(seq: 1, callID: Self.firstCallID, correlationID: Self.runToken),
            Self.runEvent(seq: 2, correlationID: Self.runToken, kind: .progress),
        ]
        let claimed: Set<RunKey> = [RunKey(tool: "gated_tool", correlationID: Self.runToken)]

        #expect(Self.placeholderTexts(for: events, claimedRuns: claimed) == [OpenToolCalls.runningOutput])
    }

    @Test("a call whose run is orphaned in the journal and not claimed gets the lost output")
    func unclaimedOrphanedRunGetsTheLostOutput() {
        let events = [
            Self.markerEvent(seq: 1, callID: Self.firstCallID, correlationID: Self.runToken),
            Self.runEvent(seq: 2, correlationID: Self.runToken, kind: .progress),
        ]

        #expect(Self.placeholderTexts(for: events) == [OpenToolCalls.lostOutput])
    }

    @Test("a call with no run in the journal gets the unrecorded output")
    func callWithoutARunGetsTheInterruptedOutput() {
        let events = [Self.markerEvent(seq: 1, callID: Self.firstCallID, correlationID: Self.runToken)]

        #expect(Self.placeholderTexts(for: events) == [OpenToolCalls.unrecordedOutput])
    }

    @Test("a call whose run completed before the crash gets the ended output")
    func completedRunGetsTheInterruptedOutput() {
        let events = [
            Self.markerEvent(seq: 1, callID: Self.firstCallID, correlationID: Self.runToken),
            Self.runEvent(seq: 2, correlationID: Self.runToken, kind: .progress),
            Self.runEvent(seq: 3, correlationID: Self.runToken, kind: .completed, outcome: .succeeded),
        ]

        #expect(Self.placeholderTexts(for: events) == [OpenToolCalls.endedOutput])
    }

    @Test("a call whose run the user cancelled gets the ended output")
    func cancelledRunGetsTheInterruptedOutput() {
        let events = [
            Self.markerEvent(seq: 1, callID: Self.firstCallID, correlationID: Self.runToken),
            Self.runEvent(seq: 2, correlationID: Self.runToken, kind: .completed, outcome: .cancelled),
        ]

        #expect(Self.placeholderTexts(for: events) == [OpenToolCalls.endedOutput])
    }

    @Test("the marker of a call carries the completion token of its run")
    @MainActor
    func markerCarriesTheCompletionToken() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let call = try #require(fixture.events().first { $0.kind == .toolCallStarted }?.entry?.toolCalls?.first)

        #expect(call.correlationID?.isEmpty == false)
    }

    @Test("a restore after a crash answers a call with a journaled orphaned run that nobody claimed with the lost output")
    @MainActor
    func restoreAnswersAnUnclaimedOrphanedRunWithTheLostOutput() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()
        let token = try #require(
            fixture.events().first { $0.kind == .toolCallStarted }?.entry?.toolCalls?.first?.correlationID)
        await fixture.started.session.outbox.journalWithoutStaging(
            event: OperationEvent(tool: tool.name, op: "run tool", correlationID: token, kind: .progress, detail: "working"))

        let restored = try await fixture.restore()
        defer { await restored.session.close() }
        let texts = Self.toolOutputTexts(in: Array(await restored.session.transcript))

        #expect(texts.filter { $0 == OpenToolCalls.lostOutput }.count == 1)
    }

    @Test("a restore after a call that finished inline in the same submission gives it the unrecorded output")
    @MainActor
    func restoreAnswersAnInlineFinishedCallWithTheInterruptedOutput() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let gated = MountFixtures.GatedTool(gate: gate, entered: entered)
        let script = ScriptedAnswerScript(
            rounds: [
                [ScriptedToolCall(id: Self.firstCallID, toolName: MountFixtures.FastTool().name, argument: .literal(Self.argumentValue))],
                [ScriptedToolCall(id: Self.secondCallID, toolName: gated.name, argument: .literal(Self.argumentValue))],
            ])
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: script, log: ScriptedAnswerLog()))
        let fixture = try await Fixture.make(over: container, tools: [MountFixtures.FastTool(), gated], gates: [gate])
        defer { await fixture.end() }
        _ = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()

        let restored = try await fixture.restore()
        defer { await restored.session.close() }
        let texts = Self.toolOutputTexts(in: Array(await restored.session.transcript))

        #expect(texts == [OpenToolCalls.unrecordedOutput, OpenToolCalls.unrecordedOutput])
    }

    @Test("a restore after a cancelled call never gives the running output")
    @MainActor
    func restoreAfterACancelledCallGivesNoRunningOutput() async throws {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await Fixture.make(
            over: Self.container(calling: tool.name, in: [Self.firstCallID]), tools: [tool], gates: [gate])
        defer { await fixture.end() }
        let answer = Task { try await fixture.started.session.respond(to: Self.prompt) }
        await entered.waitUntilOpen()
        answer.cancel()
        await gate.open()
        _ = await answer.result

        let restored = try await fixture.restore()
        defer { await restored.session.close() }
        let texts = Self.toolOutputTexts(in: Array(await restored.session.transcript))

        #expect(!texts.contains(OpenToolCalls.runningOutput))
    }

    // MARK: - A clean run

    @Test("a clean run writes one marker for each call")
    @MainActor
    func cleanRunWritesOneMarkerForEachCall() async throws {
        let fixture = try await Fixture.make(
            over: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID, Self.secondCallID]),
            tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }

        _ = try await fixture.started.session.respond(to: Self.prompt)

        let markers = try fixture.events().filter { $0.kind == .toolCallStarted }.compactMap(\.entry?.toolCalls)
        #expect(markers.map { $0.map(\.id) } == [[Self.firstCallID], [Self.secondCallID]])
    }

    @Test("a clean run still writes the .toolCalls entry of each call at the end")
    @MainActor
    func cleanRunStillWritesTheToolCallsEntries() async throws {
        let fixture = try await Fixture.make(
            over: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID, Self.secondCallID]),
            tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }

        _ = try await fixture.started.session.respond(to: Self.prompt)

        let entries = try fixture.events().filter { $0.kind == .toolCalls }.compactMap(\.entry?.toolCalls)
        #expect(entries.map { $0.map(\.id) } == [[Self.firstCallID], [Self.secondCallID]])
    }

    @Test("a clean run reconstructs each call one time")
    @MainActor
    func cleanRunReconstructsEachCallOnce() async throws {
        let fixture = try await Fixture.make(
            over: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID, Self.secondCallID]),
            tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }
        _ = try await fixture.started.session.respond(to: Self.prompt)

        let tree = try TranscriptTree.load(under: fixture.routerDirectory)
        let entries = Array(try tree.effectiveTranscript(forSession: fixture.started.session.id))

        #expect(Self.toolCallIDs(in: entries) == [[Self.firstCallID], [Self.secondCallID]])
    }

    @Test("a clean run reconstructs no placeholder output")
    @MainActor
    func cleanRunReconstructsNoPlaceholder() async throws {
        let fixture = try await Fixture.make(
            over: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID]),
            tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }
        _ = try await fixture.started.session.respond(to: Self.prompt)

        let tree = try TranscriptTree.load(under: fixture.routerDirectory)
        let entries = Array(try tree.effectiveTranscript(forSession: fixture.started.session.id))

        let placeholders = [
            OpenToolCalls.runningOutput, OpenToolCalls.lostOutput, OpenToolCalls.endedOutput,
            OpenToolCalls.unrecordedOutput,
        ]
        #expect(Set(Self.toolOutputTexts(in: entries)).isDisjoint(with: placeholders))
    }

    @Test("a clean run announces each call one time in the live events")
    @MainActor
    func cleanRunAnnouncesEachCallOnce() async throws {
        let fixture = try await Fixture.make(
            over: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID, Self.secondCallID]),
            tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }

        let events = try await collectEvents(fixture.started.session, prompt: Self.prompt)

        #expect(Self.announcedCallIDs(in: events) == [Self.firstCallID, Self.secondCallID])
        #expect(Self.runningCallIDs(in: events) == [Self.firstCallID, Self.secondCallID])
    }

    /// The ids of the ``SessionEvent/toolCall(id:name:argumentsJSON:)``
    /// events of `events`, in order.
    private static func announcedCallIDs(in events: [SessionEvent]) -> [String] {
        events.compactMap { event in
            guard case .toolCall(let id, _, _) = event else { return nil }
            return id
        }
    }

    /// The ids of the running ``SessionEvent/toolStatus(id:status:summary:output:)``
    /// events of `events`, in order.
    private static func runningCallIDs(in events: [SessionEvent]) -> [String] {
        events.compactMap { event in
            guard case .toolStatus(let id, .running, _, _) = event else { return nil }
            return id
        }
    }

    // MARK: - The reconstruction alone

    /// The recording root of the events that these tests build by hand.
    private static let routerID = ULID.generate()

    /// The session of the events that these tests build by hand.
    private static let sessionID = ULID.generate()

    /// A text entry event, as the recorder writes it.
    private static func textEvent(seq: Int, kind: TranscriptEvent.Kind, entryID: String) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: kind, text: entryID,
            entry: TranscriptEntryPayload(
                entryId: entryID, segments: [.text(id: "\(entryID)-text", content: entryID)],
                assetIds: kind == .response ? [] : nil))
    }

    /// The payload of one scripted call.
    private static func callPayload(_ id: String, correlationID: String? = nil) -> ToolCallPayload {
        ToolCallPayload(
            id: id, toolName: "gated_tool", argumentsJSON: "{\"value\":\"\(argumentValue)\"}",
            correlationID: correlationID)
    }

    /// A marker event for the call `id`, with the completion token of its run
    /// when `correlationID` is not `nil`.
    private static func markerEvent(seq: Int, callID id: String, correlationID: String? = nil) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .toolCallStarted,
            entry: TranscriptEntryPayload(
                entryId: "started-\(id)", toolCalls: [callPayload(id, correlationID: correlationID)]))
    }

    /// A journaled event of a run of the tool `gated_tool`, as the journal
    /// holds it: a segment of a `.toolOutput` entry.
    private static func runEvent(
        seq: Int, correlationID: String, kind: OperationEventKind, outcome: OperationOutcome? = nil
    ) -> TranscriptEvent {
        let event = OperationEvent(
            tool: "gated_tool", op: "run tool", correlationID: correlationID, kind: kind, detail: "run detail",
            outcome: outcome)
        return TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .toolOutput,
            entry: TranscriptEntryPayload(
                entryId: "run-\(seq)",
                segments: [TranscriptEntryMapper.segmentPayload(OperationEventSegment(id: "run-\(seq)-segment", content: event))]))
    }

    /// The text of the placeholder outputs that `OpenToolCalls.folding(_:)`
    /// makes for `events`.
    private static func placeholderTexts(
        for events: [TranscriptEvent], claimedRuns: Set<RunKey> = []
    ) -> [String] {
        OpenToolCalls.folding(events, claimedRuns: claimedRuns).filter { $0.kind == .toolOutput && $0.entry?.segments?.count == 1 }
            .compactMap { event in
                guard case .text(_, let content)? = event.entry?.segments?.first else { return nil }
                return content
            }
    }

    /// A `.toolCalls` entry event holding the calls `ids`.
    private static func toolCallsEvent(seq: Int, callIDs ids: [String]) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .toolCalls, entry: TranscriptEntryPayload(entryId: "calls-\(seq)", toolCalls: ids.map { callPayload($0) }))
    }

    /// A `.toolOutput` entry event answering the call `id`.
    private static func toolOutputEvent(seq: Int, callID id: String) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .toolOutput,
            entry: TranscriptEntryPayload(
                entryId: id, segments: [.text(id: "\(id)-text", content: "done")], toolName: "gated_tool"))
    }

    /// The kinds of `events`, in order.
    private static func kinds(of events: [TranscriptEvent]) -> [TranscriptEvent.Kind] {
        events.map(\.kind)
    }

    @Test("a marker that a later .toolCalls entry covers is dropped")
    func coveredMarkerIsDropped() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
            Self.toolCallsEvent(seq: 3, callIDs: [Self.firstCallID]),
            Self.toolOutputEvent(seq: 4, callID: Self.firstCallID),
        ]

        #expect(Self.kinds(of: OpenToolCalls.folding(events)) == [.prompt, .toolCalls, .toolOutput])
    }

    @Test("the open markers of one submission fold into one .toolCalls entry")
    func openMarkersFoldIntoOneEntry() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.textEvent(seq: 2, kind: .response, entryID: "r1"),
            Self.markerEvent(seq: 3, callID: Self.firstCallID),
            Self.markerEvent(seq: 4, callID: Self.secondCallID),
        ]

        let folded = OpenToolCalls.folding(events)

        #expect(Self.kinds(of: folded) == [.prompt, .response, .toolCalls, .toolOutput, .toolOutput])
        #expect(folded[2].entry?.toolCalls?.map(\.id) == [Self.firstCallID, Self.secondCallID])
    }

    @Test("each open call gets a placeholder output with the id of the call")
    func openCallGetsAPlaceholderWithItsID() {
        let events = [Self.markerEvent(seq: 1, callID: Self.firstCallID), Self.markerEvent(seq: 2, callID: Self.secondCallID)]

        let outputs = OpenToolCalls.folding(events).filter { $0.kind == .toolOutput }

        #expect(outputs.compactMap(\.entry?.entryId) == [Self.firstCallID, Self.secondCallID])
    }

    @Test("an open call keeps its place before the entries that follow it")
    func openCallKeepsItsPlace() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
            Self.textEvent(seq: 3, kind: .prompt, entryID: "p2"),
        ]

        #expect(Self.kinds(of: OpenToolCalls.folding(events)) == [.prompt, .toolCalls, .toolOutput, .prompt])
    }

    @Test("a restored open call pairs with its output and leaves no call open")
    func restoredOpenCallPairsWithItsOutput() throws {
        let events = [Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"), Self.markerEvent(seq: 2, callID: Self.firstCallID)]

        let entries = Array(try ContextRenderer.context(of: events))

        #expect(Self.toolCallIDs(in: entries) == [[Self.firstCallID]])
        #expect(InFlightTranscript.openCalls(in: entries).isEmpty)
    }

    @Test("the placeholder output pairs with its call by the pairing rule of the session")
    func placeholderPairsByTheSessionRule() throws {
        let events = [Self.markerEvent(seq: 1, callID: Self.firstCallID)]

        let entries = Array(try ContextRenderer.context(of: events))

        let outputID = try #require(TranscriptEntrySegments.toolOutputIDs(in: entries).first)
        #expect(
            ToolCallOutputPairing.completedToolCallId(
                forOutputEntryId: outputID, dispatched: [Self.firstCallID], completed: []) == Self.firstCallID)
    }

    // MARK: - A fork of the recorded session

    @Test("a fork inherits no marker that follows the last entry of its cut point")
    func forkInheritsNoMarkerOfALaterSubmission() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
            Self.toolCallsEvent(seq: 3, callIDs: [Self.firstCallID]),
            Self.toolOutputEvent(seq: 4, callID: Self.firstCallID),
            Self.textEvent(seq: 5, kind: .response, entryID: "r1"),
            Self.markerEvent(seq: 6, callID: Self.secondCallID),
            Self.textEvent(seq: 7, kind: .prompt, entryID: "p2"),
            Self.toolCallsEvent(seq: 8, callIDs: [Self.secondCallID]),
        ]

        let prefix = TranscriptTree.forkPrefix(of: events, entryCount: 4)

        #expect(prefix.map(\.seq) == [1, 2, 3, 4, 5])
    }

    @Test("a fork keeps a marker that a later entry of its cut point follows")
    func forkKeepsAnOpenCallBeforeItsCut() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
            Self.toolCallsEvent(seq: 3, callIDs: [Self.firstCallID]),
            Self.textEvent(seq: 4, kind: .prompt, entryID: "p2"),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 2).map(\.seq) == [1, 2, 3])
    }

    @Test("a fork keeps an open call marker at the end with its call and its output when its cut counts them")
    func forkKeepsAnOpenCallAtTheEnd() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 3).map(\.seq) == [1, 2])
    }

    @Test("a fork keeps no open call marker at the end when its cut does not count the call")
    func forkKeepsNoOpenCallBeyondItsCut() {
        let events = [
            Self.textEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.markerEvent(seq: 2, callID: Self.firstCallID),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 1).map(\.seq) == [1])
    }

    // MARK: - No read of the transcript between the passes

    /// The reads of the transcript that the session made between two tool
    /// calls before the write-ahead existed: the one read of the repetition
    /// check, which runs in the tool call of the SDK, ahead of the mount. The
    /// count is the measure of the code before this change.
    private static let readsOfTheRepetitionCheck = 1

    @Test("the write-ahead adds no read of the transcript between the end of a call and the start of the next")
    @MainActor
    func writeAheadReadsNoTranscriptBetweenCalls() async throws {
        let ledger = ReadLedger()
        let container = ReadProbingContainer(
            wrapping: Self.container(calling: MountFixtures.FastTool().name, in: [Self.firstCallID, Self.secondCallID]),
            ledger: ledger)
        let fixture = try await Fixture.make(over: container, tools: [MountFixtures.FastTool()])
        defer { await fixture.end() }

        _ = try await fixture.started.session.respond(to: Self.prompt)

        let markers = try fixture.events().filter { $0.kind == .toolCallStarted }
        #expect(markers.count == 2)
        #expect(ledger.readsBetweenFirstAndSecondCall == Self.readsOfTheRepetitionCheck)
    }
}

// MARK: - The probe

/// Counts the reads of the transcript between the end of the first tool call
/// and the start of the second one: the time of the second generation pass.
/// The tool decorator of the probe is inside the decorator of the session, so
/// the read of the repetition check in the tool call of the SDK is one of the
/// reads in that time.
private final class ReadLedger: Sendable {
    /// What the ledger counts.
    private struct State {
        /// The tool calls that are open now.
        var openCalls = 0

        /// The tool calls that started so far.
        var startedCalls = 0

        /// The reads while one call had started and none was open.
        var betweenReads = 0
    }

    /// The counts, under a lock.
    private let state = Mutex(State())

    /// The reads of the transcript between the first call and the second.
    var readsBetweenFirstAndSecondCall: Int { state.withLock { $0.betweenReads } }

    /// Notes that a tool call started.
    func callBegan() {
        state.withLock {
            $0.openCalls += 1
            $0.startedCalls += 1
        }
    }

    /// Notes that a tool call ended.
    func callEnded() {
        state.withLock { $0.openCalls -= 1 }
    }

    /// Notes one read of the transcript.
    func transcriptWasRead() {
        state.withLock {
            guard $0.openCalls == 0, $0.startedCalls == 1 else { return }
            $0.betweenReads += 1
        }
    }
}

/// A tool decorator that tells a ``ReadLedger`` when the call starts and ends.
/// It is the outermost layer of the model-facing tool, so it spans the time
/// that the SDK waits in the call.
private struct LedgerTool<Wrapped: Tool>: Tool {
    /// The tool beneath this decorator.
    let wrapped: Wrapped

    /// The ledger to tell.
    let ledger: ReadLedger

    var name: String { wrapped.name }
    var description: String { wrapped.description }
    var parameters: GenerationSchema { wrapped.parameters }
    var includesSchemaInInstructions: Bool { wrapped.includesSchemaInInstructions }

    func call(arguments: Wrapped.Arguments) async throws -> Wrapped.Output {
        ledger.callBegan()
        defer { ledger.callEnded() }
        return try await wrapped.call(arguments: arguments)
    }
}

/// A container whose backends tell a ``ReadLedger`` about each read of the
/// transcript, and whose tools tell it about each call.
private struct ReadProbingContainer: LoadedLLMContainer {
    /// The scripted container that makes the backends.
    let wrapped: ScriptedToolCallingContainer

    /// The ledger to tell.
    let ledger: ReadLedger

    init(wrapping wrapped: ScriptedToolCallingContainer, ledger: ReadLedger) {
        self.wrapped = wrapped
        self.ledger = ledger
    }

    var tokenCounter: any TokenCounter { wrapped.tokenCounter }

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        ReadProbingBackend(
            wrapping: wrapped.makeSession(instructions: instructions, tools: tools.map(probed)), ledger: ledger)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        ReadProbingBackend(
            wrapping: wrapped.makeSession(transcript: transcript, tools: tools.map(probed)), ledger: ledger)
    }

    /// `tool` in a ``LedgerTool``.
    private func probed(_ tool: any Tool) -> any Tool {
        func open<Opened: Tool>(_ opened: Opened) -> any Tool {
            LedgerTool(wrapped: opened, ledger: ledger)
        }
        return open(tool)
    }
}

/// A backend that tells a ``ReadLedger`` about each read of its transcript.
private final class ReadProbingBackend: LanguageModelSessionBackend {
    /// The backend beneath this decorator.
    private let wrapped: any LanguageModelSessionBackend

    /// The ledger to tell.
    private let ledger: ReadLedger

    init(wrapping wrapped: any LanguageModelSessionBackend, ledger: ReadLedger) {
        self.wrapped = wrapped
        self.ledger = ledger
    }

    func respond(to prompt: String, maxTokens: Int?) async throws -> String {
        try await wrapped.respond(to: prompt, maxTokens: maxTokens)
    }

    func respondWithoutReasoning(to prompt: String, maxTokens: Int?) async throws -> String {
        try await wrapped.respondWithoutReasoning(to: prompt, maxTokens: maxTokens)
    }

    func reasoningControl() async throws -> ReasoningControl {
        try await wrapped.reasoningControl()
    }

    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error> {
        wrapped.streamResponse(to: prompt, maxTokens: maxTokens)
    }

    func streamResponseFragments(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<ResponseFragment, Error> {
        wrapped.streamResponseFragments(to: prompt, maxTokens: maxTokens)
    }

    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String {
        try await wrapped.respond(to: prompt, following: grammar, maxTokens: maxTokens)
    }

    func makeFork() -> any LanguageModelSessionBackend {
        ReadProbingBackend(wrapping: wrapped.makeFork(), ledger: ledger)
    }

    func transcriptEntries() -> [Transcript.Entry] {
        ledger.transcriptWasRead()
        return wrapped.transcriptEntries()
    }

    func usageTokenCounts() -> (input: Int, output: Int)? {
        wrapped.usageTokenCounts()
    }

    func cachedInputTokenCount() -> Int? {
        wrapped.cachedInputTokenCount()
    }

    func lastGenerationCallOutputTokenCount() -> Int? {
        wrapped.lastGenerationCallOutputTokenCount()
    }

    func inFlightResponse() -> InFlightResponse? {
        wrapped.inFlightResponse()
    }

    func transcriptUpdates() -> AsyncStream<[Transcript.Entry]> {
        wrapped.transcriptUpdates()
    }

    func replacingTranscript(_ transcript: Transcript) -> any LanguageModelSessionBackend {
        ReadProbingBackend(wrapping: wrapped.replacingTranscript(transcript), ledger: ledger)
    }

    func replacingTranscript(_ transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        ReadProbingBackend(wrapping: wrapped.replacingTranscript(transcript, tools: tools), ledger: ledger)
    }
}
