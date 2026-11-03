import Foundation
import FoundationModels
import FoundationModelsExtras
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the write-ahead record of the prompt that starts a submission.
///
/// The `.prompt` entry of a submission reaches the recording at the end of
/// the submission. A crash in the first submission thus left the user
/// message of the submission nowhere. Now the session writes one
/// ``TranscriptEvent/Kind/promptStarted`` marker when the pump takes the
/// user-type mail, before the model runs. A restore drops a marker that a
/// later `.prompt` entry delivers, or a later terminal record ends, and it
/// turns an open marker into the final user message of the transcript, ahead
/// of the open tool calls (``OpenPrompts``).
///
/// The crash is simulated as the other restore suites do it: the recorded
/// session stays open and held inside its tool run, a second router over the
/// same recording root restores it, and the held run ends only at the end of
/// the test.
@Suite("Write-ahead record of the prompt that starts a submission")
struct PromptWriteAheadTests {
    /// The SDK id of the scripted call.
    private static let callID = "call-prompt-first"

    /// The prompt of the first submission.
    private static let prompt = "analyze the files in the folder"

    /// The prompt of a message that waits in the queue.
    private static let queuedPrompt = "a second message that waits"

    /// The prompt of the submission that a restored session answers.
    private static let laterPrompt = "the later message"

    /// The kinds that the transcript of a restore ends with after a crash in
    /// the first submission: the user message, then the open call and its
    /// placeholder output.
    private static let openTailKinds: [TranscriptEvent.Kind] = [.prompt, .toolCalls, .toolOutput]

    /// The prefix of the temporary folders of the tests that make their own.
    private static let tempDirPrefix = "PromptWriteAheadTests"

    // MARK: - Fixtures

    /// A session held inside the tool run of its first submission.
    private struct HeldSubmission {
        /// The recorded session, its router and its recording.
        let fixture: WriteAheadToolCallTests.Fixture

        /// The id of the mail of the first submission.
        let mailID: MailID
    }

    /// Starts the first submission of a recorded session and returns when its
    /// tool body runs: the model call is open, and the transcript has no entry
    /// of the submission on disk.
    @MainActor
    private static func holdFirstSubmission() async throws -> HeldSubmission {
        let gate = RunLatch()
        let entered = RunLatch()
        let tool = MountFixtures.GatedTool(gate: gate, entered: entered)
        let fixture = try await WriteAheadToolCallTests.Fixture.make(
            over: WriteAheadToolCallTests.container(calling: tool.name, in: [callID]), tools: [tool], gates: [gate])
        let mailID = try fixture.started.session.send(prompt)
        await entered.waitUntilOpen()
        return HeldSubmission(fixture: fixture, mailID: mailID)
    }

    /// The kind of each entry of `entries`, in order.
    private static func kinds(of entries: [Transcript.Entry]) -> [TranscriptEvent.Kind] {
        entries.map { TranscriptEntryMapper.event(from: $0).kind }
    }

    /// The text of each `.prompt` entry of `entries`, in order.
    private static func promptTexts(in entries: [Transcript.Entry]) -> [String] {
        entries.compactMap { entry in
            guard case .prompt(let prompt) = entry else { return nil }
            return prompt.segments.compactMap { segment -> String? in
                guard case .text(let text) = segment else { return nil }
                return text.content
            }.joined()
        }
    }

    /// The text of each `.promptStarted` marker of `events`, in order.
    private static func markerTexts(in events: [TranscriptEvent]) -> [String] {
        events.filter { $0.kind == .promptStarted }.compactMap(\.text)
    }

    // MARK: - A crash in the first submission

    @Test("the marker of the prompt is on disk while the first submission still runs")
    @MainActor
    func markerIsOnDiskWhileTheSubmissionRuns() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        #expect(Self.markerTexts(in: try held.fixture.events()) == [Self.prompt])
    }

    @Test("the marker holds the id of the mail that the pump took")
    @MainActor
    func markerHoldsTheMailID() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        let marker = try #require(try held.fixture.events().first { $0.kind == .promptStarted })

        #expect(marker.takenMail.map(\.id) == [held.mailID])
    }

    @Test("the prompt entry is not on disk while the first submission still runs")
    @MainActor
    func promptEntryIsNotOnDiskWhileTheSubmissionRuns() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        #expect(try held.fixture.events().filter { $0.kind == .prompt }.isEmpty)
    }

    @Test("a restore after the crash ends the transcript with the user message, the open call and its placeholder")
    @MainActor
    func restoreEndsWithTheUserMessageThenTheOpenCall() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        let restored = try await held.fixture.restore()
        defer { await restored.session.close() }
        let entries = Array(await restored.session.transcript)

        #expect(Self.kinds(of: entries).suffix(Self.openTailKinds.count) == Self.openTailKinds[...])
    }

    @Test("the user message of a restore after the crash is the prompt of the first submission")
    @MainActor
    func restoreKeepsTheTextOfTheUserMessage() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        let restored = try await held.fixture.restore()
        defer { await restored.session.close() }

        #expect(Self.promptTexts(in: Array(await restored.session.transcript)) == [Self.prompt])
    }

    @Test("the first prompt of the crashed session is not nil and is the prompt of the first submission")
    @MainActor
    func firstPromptReadsTheMarker() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }

        let prompt = try FirstPromptReader.firstPrompt(ofSessionIn: held.fixture.started.session.recordingDirectory)

        #expect(prompt == Self.prompt)
    }

    @Test("a restored session that answers a later message records its entries after the user message of the crash")
    @MainActor
    func restoredSessionKeepsTheRestoredPrefixInTheRecording() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }
        let restored = try await held.fixture.restore()
        defer { await restored.session.close() }
        _ = try await restored.session.respond(to: Self.laterPrompt)

        let tree = try TranscriptTree.load(under: held.fixture.routerDirectory)
        let recorded = Array(try tree.effectiveTranscript(forSession: held.fixture.started.session.id))
        let live = Array(await restored.session.transcript)

        #expect(Self.promptTexts(in: recorded) == [Self.prompt, Self.laterPrompt])
        #expect(Self.kinds(of: recorded) == Array(Self.kinds(of: live).drop { $0 == .instructions }))
    }

    // MARK: - A clean run

    /// Runs one clean submission with one fast tool call and gives the
    /// fixture, which the caller ends.
    private static func cleanRun() async throws -> WriteAheadToolCallTests.Fixture {
        let tool = MountFixtures.FastTool()
        let fixture = try await WriteAheadToolCallTests.Fixture.make(
            over: WriteAheadToolCallTests.container(calling: tool.name, in: [callID]), tools: [tool])
        _ = try await fixture.started.session.respond(to: prompt)
        return fixture
    }

    @Test("a clean run writes one marker for the one message that it took")
    @MainActor
    func cleanRunWritesOneMarker() async throws {
        let fixture = try await Self.cleanRun()
        defer { await fixture.end() }

        #expect(Self.markerTexts(in: try fixture.events()) == [Self.prompt])
    }

    @Test("a clean run reconstructs the prompt one time")
    @MainActor
    func cleanRunReconstructsThePromptOnce() async throws {
        let fixture = try await Self.cleanRun()
        defer { await fixture.end() }

        let tree = try TranscriptTree.load(under: fixture.routerDirectory)
        let entries = Array(try tree.effectiveTranscript(forSession: fixture.started.session.id))

        #expect(Self.promptTexts(in: entries) == [Self.prompt])
    }

    // MARK: - A queued mail

    @Test("a queued message has no marker until the pump takes it")
    @MainActor
    func queuedMailHasNoMarkerBeforeTheTake() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }
        try held.fixture.started.session.send(Self.queuedPrompt)

        #expect(Self.markerTexts(in: try held.fixture.events()) == [Self.prompt])
    }

    @Test("a queued message gets its marker when the pump takes it")
    @MainActor
    func queuedMailGetsItsMarkerAtTheTake() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }
        let queued = try held.fixture.started.session.send(Self.queuedPrompt)
        for gate in held.fixture.gates {
            await gate.open()
        }

        _ = try await held.fixture.started.session.awaitAnswer(of: queued)

        #expect(Self.markerTexts(in: try held.fixture.events()) == [Self.prompt, Self.queuedPrompt])
    }

    // MARK: - A marker write that fails

    /// The error that a failing line append throws.
    private struct MarkerWriteFailure: Error {}

    /// The prompt marker of a message with the text `text`, as a partial
    /// event.
    private static func markerPartial(text: String) -> (partial: TranscriptEvent.Partial, mailID: MailID) {
        let mail = RoutedSessionActor.userMessage(text, maxTokens: nil, mode: .reply)
        let marker = OpenPrompts.marker(of: [mail])
        let partial = TranscriptEvent.Partial(
            routerId: ULID.generate(), sessionId: ULID.generate(), kind: .promptStarted, text: marker.text,
            entry: marker.entry)
        return (partial, mail.id)
    }

    /// A recorder that fails the write of each prompt marker and writes the
    /// rest.
    private static func recorderFailingPromptMarkers(in directory: URL) -> JSONLRecorder {
        JSONLRecorder(
            directory: directory,
            appendLine: { record, file in
                if let event = record as? TranscriptEvent, event.kind == .promptStarted {
                    throw MarkerWriteFailure()
                }
                try JSONLAppend.toDisk(record, file)
            })
    }

    @Test("a marker write that fails is logged with the mail id")
    func failedMarkerWriteIsLogged() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Self.recorderFailingPromptMarkers(in: directory)
        let (partial, mailID) = Self.markerPartial(text: Self.prompt)

        let context = try await TelemetryCapture.run(forbidding: [Self.prompt]) { context in
            await recorder.append(partial, to: nil)
            return context
        }

        context.expectLogged(
            containing: "prompt marker", metadata: [RouterTelemetry.LogMetadataKey.mailId: "\(mailID)"])
    }

    @Test("a marker write that fails is counted as a lost prompt marker")
    func failedMarkerWriteIsCounted() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = Self.recorderFailingPromptMarkers(in: directory)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await recorder.append(Self.markerPartial(text: Self.prompt).partial, to: nil)
            return context
        }

        let counter = try context.metricsFactory.expectCounter(RouterTelemetry.MetricName.promptMarkerDropped, [])
        #expect(counter.totalValue == 1)
    }

    @Test("a marker that the recording root refuses is counted as a lost prompt marker")
    func refusedMarkerIsCounted() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try JSONLRecorder(owningDirectory: directory)
        let refused = JSONLRecorder(directory: directory)

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await refused.append(Self.markerPartial(text: Self.prompt).partial, to: nil)
            return context
        }
        withExtendedLifetime(owner) {}

        let counter = try context.metricsFactory.expectCounter(RouterTelemetry.MetricName.promptMarkerDropped, [])
        #expect(counter.totalValue == 1)
    }

    @Test("a tool call marker that fails to write is not counted as a lost prompt marker")
    func failedToolCallMarkerIsNotCountedAsAPromptMarker() async throws {
        let directory = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = JSONLRecorder(directory: directory, appendLine: { _, _ in throw MarkerWriteFailure() })
        let toolCall = ToolCallPayload(id: Self.callID, toolName: "gated_tool", argumentsJSON: "{}")
        let marker = TranscriptEvent.Partial(
            routerId: ULID.generate(), sessionId: ULID.generate(), kind: .toolCallStarted,
            entry: TranscriptEntryPayload(entryId: "started-" + Self.callID, toolCalls: [toolCall]))

        let context = try await TelemetryCapture.run(forbidding: []) { context in
            await recorder.append(marker, to: nil)
            return context
        }

        #expect(!context.metricRecords.contains { $0.label == RouterTelemetry.MetricName.promptMarkerDropped })
    }

    @Test("a submission still runs when the marker write of its prompt fails")
    @MainActor
    func submissionRunsWhenTheMarkerWriteFails() async throws {
        let directories = TestDirectories(prefix: Self.tempDirPrefix)
        defer { directories.remove() }
        let recorder = Self.recorderFailingPromptMarkers(in: directories.recordingsDir)
        let container = ScriptedToolCallingContainer(
            model: ScriptedToolCallingModel(script: ScriptedAnswerScript(rounds: []), log: ScriptedAnswerLog()))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir, recorder: recorder,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession()
        defer { await session.close() }

        let answer = try await session.respond(to: Self.prompt)

        #expect(!answer.isEmpty)
    }

    // MARK: - The reconstruction alone

    /// The recording root of the events that these tests build by hand.
    private static let routerID = ULID.generate()

    /// The session of the events that these tests build by hand.
    private static let sessionID = ULID.generate()

    /// A message of the user, as the pump takes it.
    private static func mail(_ text: String) -> Mail {
        RoutedSessionActor.userMessage(text, maxTokens: nil, mode: .reply)
    }

    /// An event of `kind` with the time that its `seq` implies.
    private static func event(
        seq: Int, kind: TranscriptEvent.Kind, text: String? = nil, entry: TranscriptEntryPayload? = nil
    ) -> TranscriptEvent {
        TranscriptEvent(
            routerId: routerID, sessionId: sessionID, seq: seq, ts: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: kind, text: text, entry: entry)
    }

    /// The prompt marker of `mails`, as the recorder wrote it.
    private static func markerEvent(seq: Int, mails: [Mail]) -> TranscriptEvent {
        let marker = OpenPrompts.marker(of: mails)
        return event(seq: seq, kind: .promptStarted, text: marker.text, entry: marker.entry)
    }

    /// A recorded `.prompt` entry that delivered `mails`.
    private static func promptEvent(seq: Int, delivering mails: [Mail]) -> TranscriptEvent {
        let text = ContextRenderer.promptText(delivering: mails, followedBy: nil)
        let records = mails.map {
            TranscriptEntryMapper.segmentPayload(MailRecordSegment(content: .mailDelivered($0)))
        }
        return event(
            seq: seq, kind: .prompt, text: text,
            entry: TranscriptEntryPayload(
                entryId: "prompt-\(seq)", segments: [.text(id: "prompt-\(seq)-text", content: text)] + records))
    }

    /// A `.mail` event that holds the record `record`.
    private static func mailEvent(seq: Int, record: MailRecord) -> TranscriptEvent {
        event(
            seq: seq, kind: .mail,
            entry: TranscriptEntryPayload(
                entryId: "mail-\(seq)",
                segments: [TranscriptEntryMapper.segmentPayload(MailRecordSegment(content: record))]))
    }

    /// The kinds of `events`, in order.
    private static func kinds(of events: [TranscriptEvent]) -> [TranscriptEvent.Kind] {
        events.map(\.kind)
    }

    /// The text of the `.prompt` events of `events`, in order.
    private static func promptTexts(in events: [TranscriptEvent]) -> [String] {
        events.filter { $0.kind == .prompt }.compactMap(\.text)
    }

    @Test("a marker that a later prompt entry delivers is dropped")
    func deliveredMarkerIsDropped() {
        let message = Self.mail(Self.prompt)
        let events = [Self.markerEvent(seq: 1, mails: [message]), Self.promptEvent(seq: 2, delivering: [message])]

        #expect(OpenPrompts.folding(events).map(\.seq) == [2])
    }

    @Test("a marker that a later cancelled record ends is dropped")
    func cancelledMarkerIsDropped() {
        let message = Self.mail(Self.prompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [message]), Self.mailEvent(seq: 2, record: .cancelled(message.id)),
        ]

        #expect(Self.kinds(of: OpenPrompts.folding(events)) == [.mail])
    }

    @Test("a marker that a later answer-ended record ends is dropped")
    func answerEndedMarkerIsDropped() {
        let message = Self.mail(Self.prompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [message]), Self.mailEvent(seq: 2, record: .answerEnded(message.id)),
        ]

        #expect(Self.kinds(of: OpenPrompts.folding(events)) == [.mail])
    }

    @Test("a marker that only a lost record follows stays open")
    func lostMarkerStaysOpen() {
        let message = Self.mail(Self.prompt)
        let events = [Self.markerEvent(seq: 1, mails: [message]), Self.mailEvent(seq: 2, record: .lost(message.id))]

        #expect(Self.promptTexts(in: OpenPrompts.folding(events)) == [Self.prompt])
    }

    @Test("a prompt entry that came before the marker does not cover it")
    func earlierPromptDoesNotCover() {
        let message = Self.mail(Self.prompt)
        let events = [Self.promptEvent(seq: 1, delivering: [message]), Self.markerEvent(seq: 2, mails: [message])]

        #expect(Self.kinds(of: OpenPrompts.folding(events)) == [.prompt, .prompt])
    }

    @Test("an open marker becomes one prompt entry with the text of its message")
    func openMarkerBecomesAPromptEntry() {
        let events = [Self.markerEvent(seq: 1, mails: [Self.mail(Self.prompt)])]

        #expect(Self.promptTexts(in: OpenPrompts.folding(events)) == [Self.prompt])
    }

    @Test("an open marker of two messages becomes one prompt entry with both texts")
    func openMarkerOfTwoMessagesJoinsTheTexts() {
        let events = [Self.markerEvent(seq: 1, mails: [Self.mail(Self.prompt), Self.mail(Self.queuedPrompt)])]

        #expect(
            Self.promptTexts(in: OpenPrompts.folding(events))
                == [[Self.prompt, Self.queuedPrompt].joined(separator: ContextRenderer.blockSeparator)])
    }

    @Test("a marker of two messages keeps only the message that no prompt entry delivers")
    func partlyDeliveredMarkerKeepsTheOpenMessage() {
        let delivered = Self.mail(Self.prompt)
        let open = Self.mail(Self.queuedPrompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [delivered, open]), Self.promptEvent(seq: 2, delivering: [delivered]),
        ]

        #expect(Self.promptTexts(in: OpenPrompts.folding(events)) == [Self.queuedPrompt, Self.prompt])
    }

    @Test("the render puts the open user message before the open calls that follow it")
    func renderPutsTheUserMessageBeforeTheOpenCalls() throws {
        let call = ToolCallPayload(id: Self.callID, toolName: "gated_tool", argumentsJSON: "{}")
        let events = [
            Self.markerEvent(seq: 1, mails: [Self.mail(Self.prompt)]),
            Self.event(
                seq: 2, kind: .toolCallStarted,
                entry: TranscriptEntryPayload(entryId: "started-" + Self.callID, toolCalls: [call])),
        ]

        let transcript = try ContextRenderer.context(of: events)

        #expect(Self.kinds(of: Array(transcript)) == Self.openTailKinds)
    }

    // MARK: - A fork of the recorded session

    /// A `.prompt` or `.response` entry event with the text `entryID`.
    private static func entryEvent(seq: Int, kind: TranscriptEvent.Kind, entryID: String) -> TranscriptEvent {
        event(
            seq: seq, kind: kind, text: entryID,
            entry: TranscriptEntryPayload(
                entryId: entryID, segments: [.text(id: "\(entryID)-text", content: entryID)],
                assetIds: kind == .response ? [] : nil))
    }

    @Test("a fork inherits no prompt marker that follows the last entry of its cut point")
    func forkInheritsNoPromptMarkerOfALaterSubmission() {
        let queued = Self.mail(Self.queuedPrompt)
        let events = [
            Self.entryEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.entryEvent(seq: 2, kind: .response, entryID: "r1"),
            Self.markerEvent(seq: 3, mails: [queued]),
            Self.promptEvent(seq: 4, delivering: [queued]),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 2).map(\.seq) == [1, 2])
    }

    @Test("a fork keeps a prompt marker that a later entry of its cut point follows")
    func forkKeepsAPromptMarkerBeforeItsCut() {
        let message = Self.mail(Self.prompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [message]),
            Self.promptEvent(seq: 2, delivering: [message]),
            Self.entryEvent(seq: 3, kind: .response, entryID: "r1"),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 1).map(\.seq) == [1, 2])
    }

    @Test("a fork keeps a prompt marker that no entry covers when its cut counts the user message of the marker")
    func forkKeepsAnOpenPromptMarkerAtTheEnd() {
        let events = [
            Self.entryEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.entryEvent(seq: 2, kind: .response, entryID: "r1"),
            Self.markerEvent(seq: 3, mails: [Self.mail(Self.queuedPrompt)]),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 3).map(\.seq) == [1, 2, 3])
    }

    @Test("a fork keeps no open prompt marker that its cut does not count")
    func forkKeepsNoOpenPromptMarkerBeyondItsCut() {
        let events = [
            Self.entryEvent(seq: 1, kind: .prompt, entryID: "p1"),
            Self.entryEvent(seq: 2, kind: .response, entryID: "r1"),
            Self.markerEvent(seq: 3, mails: [Self.mail(Self.queuedPrompt)]),
        ]

        #expect(TranscriptTree.forkPrefix(of: events, entryCount: 2).map(\.seq) == [1, 2])
    }

    @Test("a fork of a restored parent with an open prompt keeps the prompt, the open call and its output before its response")
    @MainActor
    func forkOfARestoredParentKeepsTheOpenPrompt() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }
        let parentID = held.fixture.started.session.id
        let cut = try RecordedForkFixtures.cut(atEndOf: parentID, under: held.fixture.routerDirectory)
        let forkID = ULID.generate()
        let forkDirectory = try RecordedForkFixtures.writeFork(
            id: forkID, under: held.fixture.started.session.recordingDirectory, cut: cut)
        let transcript = forkDirectory.appendingPathComponent(transcriptFileName, isDirectory: false)
        for event in [
            Self.entryEvent(seq: 1_000, kind: .prompt, entryID: "fork-prompt"),
            Self.entryEvent(seq: 1_001, kind: .response, entryID: "fork-response"),
        ] {
            try JSONLAppend.toDisk(event, transcript)
        }

        let restored = Array(
            try TranscriptTree.load(under: held.fixture.routerDirectory).effectiveTranscript(forSession: forkID))

        #expect(Self.kinds(of: restored).suffix(5) == [.prompt, .toolCalls, .toolOutput, .prompt, .response])
        #expect(Self.promptTexts(in: restored) == [Self.prompt, "fork-prompt"])
    }

    @Test("the first prompt of a fork of a restored parent with an open prompt is the open prompt")
    @MainActor
    func firstPromptOfAForkReadsTheOpenPromptOfItsParent() async throws {
        let held = try await Self.holdFirstSubmission()
        defer { await held.fixture.end() }
        let cut = try RecordedForkFixtures.cut(
            atEndOf: held.fixture.started.session.id, under: held.fixture.routerDirectory)
        let forkDirectory = try RecordedForkFixtures.writeFork(
            under: held.fixture.started.session.recordingDirectory, cut: cut)

        #expect(try FirstPromptReader.firstPrompt(ofSessionIn: forkDirectory) == Self.prompt)
    }

    // MARK: - The first prompt of a session whose first message was cancelled

    @Test("the first prompt skips the marker of a message that a later cancelled record ended")
    func firstPromptSkipsACancelledMarker() throws {
        let cancelled = Self.mail(Self.queuedPrompt)
        let answered = Self.mail(Self.prompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [cancelled]),
            Self.mailEvent(seq: 2, record: .cancelled(cancelled.id)),
            Self.markerEvent(seq: 3, mails: [answered]),
            Self.promptEvent(seq: 4, delivering: [answered]),
        ]

        #expect(try Self.firstPrompt(of: events) == Self.prompt)
    }

    @Test("the first prompt keeps the marker of a message that no record ends")
    func firstPromptKeepsAnOpenMarker() throws {
        let open = Self.mail(Self.queuedPrompt)
        let later = Self.mail(Self.prompt)
        let events = [
            Self.markerEvent(seq: 1, mails: [open]),
            Self.markerEvent(seq: 2, mails: [later]),
            Self.promptEvent(seq: 3, delivering: [later]),
        ]

        #expect(try Self.firstPrompt(of: events) == Self.queuedPrompt)
    }

    /// The first prompt that the reader finds in a root session folder that
    /// holds `events`.
    private static func firstPrompt(of events: [TranscriptEvent]) throws -> String? {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
            .appendingPathComponent(ULID.generate().description, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try SessionRecordFixtures.write(SessionRecordFixtures.record(in: directory), to: directory)
        let transcript = directory.appendingPathComponent(transcriptFileName, isDirectory: false)
        for event in events {
            try JSONLAppend.toDisk(event, transcript)
        }
        return try FirstPromptReader.firstPrompt(ofSessionIn: directory)
    }
}
