import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// Exercises the mail records of the transcript (`mailbox.md`, mail step 2,
/// part D).
///
/// The transcript records the life of each mail: ``MailRecord/mailQueued(_:)``
/// when the mail goes into the queue, ``MailRecord/mailDelivered(_:)`` on the
/// `.prompt` entry of the submission that delivers it, and one terminal record
/// (``MailRecord/answerEnded(_:)``, ``MailRecord/cancelled(_:)`` or
/// ``MailRecord/lost(_:)``). ``ContextRenderer`` renders the context from the
/// entries only, so a mail that the queue delivered two times is in the
/// context one time. A restore gives one ``SessionEvent/lost(_:)`` to each
/// mail that has no terminal record, and runs nothing again.
///
/// Everything runs on ``SessionMessagePumpTests/PumpProbeBackend``. The suite
/// needs no network and no GPU.
@Suite("Mail records in the transcript, the context render, and the restore of lost mail")
struct MailTranscriptTests {
    /// The backend the suite scripts.
    private typealias Backend = SessionMessagePumpTests.PumpProbeBackend

    /// The suite's temp-directory prefix.
    private static let tempDirPrefix = "MailTranscriptTests"

    /// The prompt of the first message.
    private static let firstPrompt = "first question"

    /// The prompt of the second message.
    private static let secondPrompt = "second question"

    /// The prompt of the third message.
    private static let thirdPrompt = "third question"

    /// The prompt that a replace gives to a queued message.
    private static let replacedPrompt = "replaced question"

    // MARK: - Fixtures

    /// Makes a router over `backend` that records into `recorder`.
    ///
    /// - Parameters:
    ///   - id: The recording root id of the router.
    ///   - backend: The backend of each new session.
    ///   - cacheDir: The cache directory of the router.
    ///   - recordingsDir: The durable root of the transcripts, or `nil`.
    ///   - recorder: The recorder of the router.
    /// - Returns: The router.
    private static func makeRouter(
        id: ULID = .generate(),
        over backend: Backend,
        cacheDir: URL,
        recordingsDir: URL? = nil,
        recorder: any TranscriptRecorder
    ) -> Router {
        RouterTestFixtures.makeRouter(
            id: id, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder,
            loader: StubModelLoader(
                container: SessionMessagePumpTests.PumpProbeContainer(backend: backend),
                dimension: RouterTestFixtures.stubDimension))
    }

    /// Makes a session over `backend` that records into `recorder`.
    ///
    /// - Parameters:
    ///   - backend: The backend the session runs on.
    ///   - dir: The cache directory of the router.
    ///   - recorder: The recorder of the router.
    /// - Returns: The session, and the router and the profile that keep its
    ///   model resident.
    private static func makeSession(
        over backend: Backend, dir: URL, recorder: any TranscriptRecorder
    ) async throws -> (session: any RoutedSession, keep: (Router, LanguageModelProfile)) {
        let router = makeRouter(over: backend, cacheDir: dir, recorder: recorder)
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile.standard.makeSession(), (router, profile))
    }

    /// The name of the case of `record`, for a short comparison.
    ///
    /// - Parameter record: A mail record.
    /// - Returns: The name of its case.
    private static func name(of record: MailRecord) -> String {
        switch record {
        case .mailQueued: "mailQueued"
        case .mailDelivered: "mailDelivered"
        case .replaced: "replaced"
        case .cancelled: "cancelled"
        case .answerEnded: "answerEnded"
        case .lost: "lost"
        }
    }

    /// The records of the mail `id` in `events`, in transcript order.
    ///
    /// - Parameters:
    ///   - id: The id of the mail.
    ///   - events: A recorded stream.
    /// - Returns: The names of the records of `id`.
    private static func records(of id: MailID, in events: [TranscriptEvent]) -> [String] {
        events.flatMap(\.mailRecords).filter { $0.mailID == id }.map(name(of:))
    }

    /// The ids of the delivered mail in `events`, in transcript order.
    ///
    /// - Parameter events: A recorded stream.
    /// - Returns: The ids.
    private static func deliveredIds(in events: [TranscriptEvent]) -> [MailID] {
        events.flatMap(\.mailRecords).compactMap { record in
            guard case .mailDelivered(let mail) = record else { return nil }
            return mail.id
        }
    }

    /// Reads `feed` to its end. Call it after ``RoutedSession/close()``.
    ///
    /// - Parameter feed: The session-wide feed of one session.
    /// - Returns: Each event the feed delivered, in order.
    private static func events(of feed: AsyncStream<SessionOutput>) async -> [SessionEvent] {
        var events: [SessionEvent] = []
        for await output in feed {
            events.append(output.event)
        }
        return events
    }

    /// The text that the model reads of each entry of `transcript`.
    ///
    /// - Parameter transcript: A rendered context.
    /// - Returns: The text of each entry, in order.
    private static func texts(of transcript: Transcript) -> [String] {
        transcript.map(CharacterTokenCounter.content(of:))
    }

    /// Whether `transcript` holds a ``MailRecordSegment`` in any entry.
    ///
    /// - Parameter transcript: A rendered context.
    /// - Returns: `true` when an entry holds a mail record.
    private static func holdsMailRecords(_ transcript: Transcript) -> Bool {
        transcript.contains { entry in
            guard case .prompt(let prompt) = entry else { return false }
            return prompt.segments.contains { segment in
                guard case .structure(let structured) = segment else { return false }
                return (try? MailRecordSegment(structuredSegment: structured)) != nil
            }
        }
    }

    // MARK: - The life of one mail

    @Test(
        "a sent message records mailQueued, then mailDelivered on its prompt entry, then answerEnded; the render holds no mail record"
    )
    func anAnsweredMessageRecordsItsLife() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let backend = Backend(script: [:])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let id = try session.send(Self.firstPrompt)
        _ = try await session.awaitTerminal(of: id)
        await session.close()

        let events = await recorder.events
        #expect(Self.records(of: id, in: events) == ["mailQueued", "mailDelivered", "answerEnded"])
        let prompt = try #require(events.first { $0.kind == .prompt })
        #expect(prompt.mailRecords.map(\.mailID) == [id])
        #expect(prompt.text == Self.firstPrompt)

        // The records are not entries: the render holds the prompt and the
        // response only, and no mail record segment.
        let context = try ContextRenderer.context(of: events)
        #expect(Self.texts(of: context) == [Self.firstPrompt, Backend.answer(ofCall: 1)])
        #expect(!Self.holdsMailRecords(context))
        withExtendedLifetime(keep) {}
    }

    @Test("the delivered records are in take order, on the prompt entry of the submission that delivers the mail")
    func deliveredRecordsAreInTakeOrder() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let held = try session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = try session.send(Self.secondPrompt)
        let third = try session.send(Self.thirdPrompt)
        await latch.open()
        _ = try await session.awaitTerminal(of: third)
        await session.close()

        let events = await recorder.events
        #expect(Self.deliveredIds(in: events) == [held, second, third])
        // Each prompt entry carries the records of the mail it delivered, and
        // its text renders that mail in the same order.
        for prompt in events.filter({ $0.kind == .prompt }) {
            let delivered = prompt.mailRecords.compactMap { record -> Mail? in
                guard case .mailDelivered(let mail) = record else { return nil }
                return mail
            }
            #expect(!delivered.isEmpty)
            #expect(prompt.text == ContextRenderer.promptText(delivering: delivered, followedBy: nil))
        }
        for id in [held, second, third] {
            #expect(Self.records(of: id, in: events).filter { $0 == "answerEnded" }.count == 1)
        }
        withExtendedLifetime(keep) {}
    }

    // MARK: - cancel, replace and cancelAll

    @Test(
        "replace and cancel of a queued mail, and cancelAll, write their records; each mail gets one terminal record; the render holds none of them"
    )
    func signalsWriteTheirRecords() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let held = try session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let replaced = try session.send(Self.secondPrompt)
        let swept = try session.send(Self.thirdPrompt)
        let newBody = MailBody.userMessage(prompt: Self.replacedPrompt, options: UserMessageOptions())

        let replace = session.replace(replaced, with: newBody)
        #expect(try await session.awaitTerminal(of: replace) == .signalDone(replace))
        let cancel = session.cancel(replaced)
        #expect(try await session.awaitTerminal(of: cancel) == .signalDone(cancel))
        let stop = session.cancelAll()
        #expect(try await session.awaitTerminal(of: stop) == .signalDone(stop))
        await latch.open()
        #expect(await session.becomesIdle())
        await session.close()

        let events = await recorder.events
        #expect(Self.records(of: replaced, in: events) == ["mailQueued", "replaced", "cancelled"])
        let replaceRecord = events.flatMap(\.mailRecords).first { Self.name(of: $0) == "replaced" }
        #expect(replaceRecord == .replaced(replaced, body: newBody))
        #expect(Self.records(of: swept, in: events) == ["mailQueued", "cancelled"])
        // The held answer was stopped before its call wrote an entry, so it
        // has no delivered record, and its failed answer ends it.
        #expect(Self.records(of: held, in: events) == ["mailQueued", "answerEnded"])
        for id in [held, replaced, swept] {
            #expect(events.flatMap(\.mailRecords).filter { $0.mailID == id && $0.isTerminal }.count == 1)
        }
        #expect(try ContextRenderer.context(of: events).isEmpty)
        withExtendedLifetime(keep) {}
    }

    // MARK: - A requeued mail

    @Test(
        "run mail that a failed submission gives back to the queue is delivered two times, but the transcript and the render hold it one time"
    )
    func aRequeuedMailIsInTheContextOneTime() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let backend = Backend(script: [1: .fail])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)
        let feed = await session.streamSessionEvents()

        let event = MailQueueFixtures.progressEvent(detail: "a step that rides two submissions")
        let runMail = try await MailQueueFixtures.post(event, to: session)
        let line = OperationEventSegment.renderedLine(for: event)

        // The first call fails before it writes an entry, so the run mail
        // goes back to the queue (attach or requeue).
        await #expect(throws: (any Error).self) {
            _ = try await session.respond(to: Self.firstPrompt)
        }
        #expect(session.outbox.queue.pending.map(\.id).contains(runMail))
        _ = try await session.respond(to: Self.secondPrompt)
        await session.close()

        // The model got the mail two times: the failed call and the next one.
        #expect(backend.prompts.count == 2)
        #expect(backend.prompts.allSatisfy { $0.contains(line) })
        let outputEvents = await Self.events(of: feed)
        #expect(outputEvents.filter { $0 == .mailDelivered(runMail) }.count == 2)

        // The transcript holds one delivered record, on the prompt entry of
        // the call that wrote an entry, and the render holds the line one time.
        let events = await recorder.events
        #expect(Self.deliveredIds(in: events).filter { $0 == runMail }.count == 1)
        let context = try ContextRenderer.context(of: events)
        let rendered = Self.texts(of: context).joined(separator: "\n")
        #expect(rendered.components(separatedBy: line).count - 1 == 1)
        #expect(!Self.holdsMailRecords(context))
        withExtendedLifetime(keep) {}
    }

    // MARK: - A retried attempt

    @Test(
        "a rejected tool call runs the attempt again; the mail has one delivered record, on the prompt entry of the retry that the model read"
    )
    func aRejectedCallRetryRecordsTheMailOnTheRetryPrompt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let latch = RunLatch()
        await latch.open()
        let backend = Backend(script: [1: .holdThenReject(latch)])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let id = try session.send(Self.firstPrompt)
        _ = try await session.awaitTerminal(of: id)
        await session.close()

        // The first call threw before it wrote an entry, and the retry
        // answered.
        #expect(backend.prompts.count == 2)
        let finalPrompt = try #require(backend.prompts.last)
        let events = await recorder.events
        #expect(Self.records(of: id, in: events) == ["mailQueued", "mailDelivered", "answerEnded"])
        let delivering = events.promptsDelivering(id)
        #expect(delivering.count == 1)
        #expect(delivering.first?.text == finalPrompt)
        let context = try ContextRenderer.context(of: events)
        #expect(Self.texts(of: context) == [finalPrompt, Backend.answer(ofCall: 2)])
        withExtendedLifetime(keep) {}
    }

    @Test(
        "a rejected retry that a waiting message joins records each mail one time, on the prompt of the retry, in take order"
    )
    func aRejectedRetryWithJoiningMailRecordsEachMailOneTime() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let latch = RunLatch()
        let backend = Backend(script: [1: .holdThenReject(latch)])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let first = try session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let second = try session.send(Self.secondPrompt)
        await latch.open()
        _ = try await session.awaitTerminal(of: second)
        await session.close()

        #expect(backend.prompts.count == 2)
        let finalPrompt = try #require(backend.prompts.last)
        let events = await recorder.events
        #expect(Self.deliveredIds(in: events) == [first, second])
        for id in [first, second] {
            let delivering = events.promptsDelivering(id)
            #expect(delivering.count == 1)
            #expect(delivering.first?.text == finalPrompt)
        }
        let rendered = Self.texts(of: try ContextRenderer.context(of: events)).joined(separator: "\n")
        for prompt in [Self.firstPrompt, Self.secondPrompt] {
            #expect(rendered.components(separatedBy: prompt).count - 1 == 1)
        }
        withExtendedLifetime(keep) {}
    }

    // MARK: - A failed attempt with no recovery, over seed entries

    /// How many seeded answers the backend transcript starts with. The
    /// session did not record them, so the diff of the first submission
    /// holds their `.prompt` entries too.
    private static let seedAnswerCount = 3

    /// The prompt of the seeded answer `index`.
    ///
    /// - Parameter index: The index of the seeded answer.
    /// - Returns: The prompt text.
    private static func seedPrompt(_ index: Int) -> String {
        "seed message \(index)"
    }

    /// The response of the seeded answer `index`.
    ///
    /// - Parameter index: The index of the seeded answer.
    /// - Returns: The response text.
    private static func seedResponse(_ index: Int) -> String {
        "seed answer \(index)"
    }

    /// The seed entries: one `.prompt` and one `.response` entry for each
    /// seeded answer.
    ///
    /// - Returns: The entries, in transcript order.
    private static func seedEntries() -> [Transcript.Entry] {
        (0..<seedAnswerCount).flatMap { index -> [Transcript.Entry] in
            [
                Backend.promptEntry(seedPrompt(index)),
                .response(Transcript.Response(segments: [.text(Transcript.TextSegment(content: seedResponse(index)))])),
            ]
        }
    }

    /// The texts of the seed entries, in transcript order.
    ///
    /// - Returns: The prompt and the response text of each seeded answer.
    private static func seedTexts() -> [String] {
        (0..<seedAnswerCount).flatMap { [seedPrompt($0), seedResponse($0)] }
    }

    /// The recorded `.prompt` events of `events` whose text is a seed prompt.
    ///
    /// - Parameter events: A recorded stream.
    /// - Returns: The seed prompt events, in transcript order.
    private static func seedPrompts(in events: [TranscriptEvent]) -> [TranscriptEvent] {
        let seeds = Set((0..<seedAnswerCount).map(seedPrompt))
        return events.filter { $0.kind == .prompt && seeds.contains($0.text ?? "") }
    }

    /// Whether `event` is the terminal event ``SessionEvent/answerFailed(_:)``.
    ///
    /// - Parameter event: One event of a session.
    /// - Returns: `true` for an answer failure.
    private static func isAnswerFailed(_ event: SessionEvent) -> Bool {
        if case .answerFailed = event {
            return true
        }
        return false
    }

    @Test(
        "a failed attempt with no recovery over seed entries records the mail on the prompt of that submission, one time, and not on a seed prompt"
    )
    func aFailedAttemptRecordsTheMailOnItsOwnPrompt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let backend = Backend(script: [1: .failAfterPrompt], seedEntries: Self.seedEntries())
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let id = try session.send(Self.firstPrompt)
        #expect(Self.isAnswerFailed(try await session.awaitTerminal(of: id)))
        await session.close()

        let events = await recorder.events
        #expect(Self.records(of: id, in: events) == ["mailQueued", "mailDelivered", "answerEnded"])
        let delivering = events.promptsDelivering(id)
        #expect(delivering.count == 1)
        #expect(delivering.first?.text == Self.firstPrompt)
        let seeds = Self.seedPrompts(in: events)
        #expect(seeds.count == Self.seedAnswerCount)
        #expect(seeds.allSatisfy { $0.mailRecords.isEmpty })
        // The render holds each seed entry as it is, then the mail one time.
        // The close of the failed answer has no text.
        let rendered = Self.texts(of: try ContextRenderer.context(of: events)).filter { !$0.isEmpty }
        #expect(rendered == Self.seedTexts() + [Self.firstPrompt])
        withExtendedLifetime(keep) {}
    }

    @Test(
        "a failed attempt with no recovery that wrote no prompt, over seed entries, puts no mail record on a seed prompt, and the render holds the seed entries as they are"
    )
    func aFailedAttemptWithNoPromptRecordsNoMailOnASeedPrompt() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let backend = Backend(script: [1: .fail], seedEntries: Self.seedEntries())
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        let id = try session.send(Self.firstPrompt)
        #expect(Self.isAnswerFailed(try await session.awaitTerminal(of: id)))
        await session.close()

        // The model got no prompt entry of the submission, so the live
        // context does not hold the mail, and the transcript holds no
        // delivered record of it.
        let events = await recorder.events
        #expect(Self.records(of: id, in: events) == ["mailQueued", "answerEnded"])
        let seeds = Self.seedPrompts(in: events)
        #expect(seeds.count == Self.seedAnswerCount)
        #expect(seeds.allSatisfy { $0.mailRecords.isEmpty })
        let rendered = Self.texts(of: try ContextRenderer.context(of: events)).filter { !$0.isEmpty }
        #expect(rendered == Self.seedTexts())
        withExtendedLifetime(keep) {}
    }

    // MARK: - The render grows at its end

    @Test("between two answers the render only grows at its end")
    func theRenderGrowsAtItsEnd() async throws {
        let dir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = InMemoryRecorder()
        let backend = Backend(script: [:])
        let (session, keep) = try await Self.makeSession(over: backend, dir: dir, recorder: recorder)

        _ = try await session.respond(to: Self.firstPrompt)
        let before = try ContextRenderer.context(of: await recorder.events)
        _ = try await MailQueueFixtures.post(MailQueueFixtures.progressEvent(detail: "between answers"), to: session)
        _ = try await session.respond(to: Self.secondPrompt)
        await session.close()
        let after = try ContextRenderer.context(of: await recorder.events)

        #expect(after.count > before.count)
        #expect(Array(after.prefix(before.count)).map(\.id) == before.map(\.id))
        #expect(Self.texts(of: Transcript(entries: after.prefix(before.count))) == Self.texts(of: before))
        withExtendedLifetime(keep) {}
    }

    // MARK: - Restore

    @Test(
        "a restore gives one lost to each mail with no terminal record, records it, runs nothing again, and a second restore gives none"
    )
    func aRestoreReportsLostMailOneTime() async throws {
        let cacheDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        let recordingsDir = RouterTestFixtures.makeTempDir(prefix: Self.tempDirPrefix)
        defer {
            try? FileManager.default.removeItem(at: cacheDir)
            try? FileManager.default.removeItem(at: recordingsDir)
        }
        // One recording root admits one live writer, so all the routers share
        // this recorder.
        let recorder = JSONLRecorder(directory: recordingsDir)
        let latch = RunLatch()
        let backend = Backend(script: [1: .hold(latch)])
        let router1 = Self.makeRouter(
            over: backend, cacheDir: cacheDir, recordingsDir: recordingsDir, recorder: recorder)
        let profile1 = try await router1.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile1.standard.makeSession()
        let routerDirectory = RouterTestFixtures.routerDirectory(routerId: router1.id, recordingsDir: recordingsDir)

        // The held answer and the mail behind it have no terminal record when
        // the process stops.
        let held = try session.send(Self.firstPrompt)
        try await BoundedWait.awaitPrompts(1, in: { backend.prompts })
        let queued = try session.send(Self.secondPrompt)
        let sessionId = session.id
        #expect(
            await BoundedWait.conditionReached("the two queued records are on disk") {
                let tree = try? TranscriptTree.load(under: routerDirectory)
                let events = (try? tree?.events(forSession: sessionId)) ?? []
                return events.flatMap(\.mailRecords).count == 2
            })

        // The first restore reports each mail as lost, in record order.
        let router2 = Self.makeRouter(
            id: router1.id, over: Backend(script: [:]), cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: recorder)
        let profile2 = try await router2.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let restored = try await profile2.standard.restoreSessionTree(root: sessionId).root
        #expect(try await restored.awaitTerminal(of: held) == .lost(held))
        #expect(try await restored.awaitTerminal(of: queued) == .lost(queued))
        // A lost mail goes back to no queue, so the restore runs nothing.
        #expect(await restored.pendingMessages().isEmpty)
        #expect(await restored.becomesIdle())

        // The second restore finds the lost records, so it reports nothing.
        let router3 = Self.makeRouter(
            id: router1.id, over: Backend(script: [:]), cacheDir: cacheDir, recordingsDir: recordingsDir,
            recorder: recorder)
        let profile3 = try await router3.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        _ = try await profile3.standard.restoreSessionTree(root: sessionId)

        let events = try TranscriptTree.load(under: routerDirectory).events(forSession: sessionId)
        #expect(Self.records(of: held, in: events) == ["mailQueued", "lost"])
        #expect(Self.records(of: queued, in: events) == ["mailQueued", "lost"])
        #expect(!events.contains { $0.kind == .prompt })
        #expect(backend.prompts == [Self.firstPrompt])

        await latch.open()
        await session.close()
        withExtendedLifetime((router1, profile1, router2, profile2, router3, profile3)) {}
    }

    // MARK: - Schema version

    @Test("the recording schema version is v3, and a recording with no version still reads as v2")
    func theSchemaVersionIsV3() {
        #expect(RecordingSchemaVersion.current == RecordingSchemaVersion.v3)
        #expect(RecordingSchemaVersion.implicit == RecordingSchemaVersion.v2)
    }
}
