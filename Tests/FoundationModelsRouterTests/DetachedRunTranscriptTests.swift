import Foundation
import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Exercises task `^zn8n9md`: a detached run's own events reach the
/// transcript when they happen, as real `.toolOutput` entries correlated to
/// the run by its completion token, instead of only riding the next turn's
/// prompt as text.
///
/// Everything runs against stubs — a plain ``StubSessionBackend`` and an
/// ``InMemoryRecorder`` — so the suite needs no network and no GPU.
@Suite("Detached run journaling: a posted event becomes a correlated transcript entry")
struct DetachedRunTranscriptTests {
    // MARK: - Stub container

    private struct BasicLLMContainer: PlainTranscriptStubContainer {
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            StubSessionBackend()
        }
    }

    // MARK: - Fixtures

    /// Builds a fresh router + resolved profile + vended session over a plain
    /// stub backend, recording through `recorder`.
    ///
    /// - Parameter recorder: The recorder every vended session records
    ///   through.
    /// - Returns: The vended session and the temp directory to clean up.
    private static func makeSession(
        recorder: any TranscriptRecorder
    ) async throws -> (session: RoutedSession, dir: URL) {
        let dir = RouterTestFixtures.makeTempDir(prefix: "DetachedRunTranscriptTests")
        let router = RouterTestFixtures.makeRouter(
            cacheDir: dir,
            recorder: recorder,
            loader: StubModelLoader(
                container: BasicLLMContainer(), dimension: RouterTestFixtures.stubDimension)
        )
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        return (profile.standard.makeSession(), dir)
    }

    /// Builds a canned ``OperationEvent`` for one detached run.
    ///
    /// - Parameters:
    ///   - completionToken: The run's completion token, which is also its
    ///     event correlation id.
    ///   - kind: The event's kind.
    ///   - detail: The event's detail payload.
    /// - Returns: The event.
    private static func event(
        completionToken: String = "01AN4Z07BY79KA1307SR9X4MV3",
        kind: OperationEventKind,
        detail: String
    ) -> OperationEvent {
        OperationEvent(
            tool: "shell", op: "run command", correlationID: completionToken, kind: kind,
            detail: detail)
    }

    /// Every ``OperationEvent`` `events` carries on a `.toolOutput`-kind
    /// recorded event, paired with the entry id it was journaled under, in
    /// recorded order.
    ///
    /// - Parameter events: The recorded events to scan.
    /// - Returns: One `(entryId, event)` pair per journaled operation event.
    private static func journaledRunEvents(
        in events: [TranscriptEvent]
    ) -> [(entryId: String, event: OperationEvent)] {
        events.filter { $0.kind == .toolOutput }.flatMap { recorded -> [(String, OperationEvent)] in
            guard let entry = recorded.entry else { return [] }
            return (entry.segments ?? []).compactMap { segment in
                guard case .custom(_, let discriminator, let contentJSON, _) = segment,
                    discriminator == OperationEventSegment.typeDiscriminator,
                    let decoded = try? JSONDecoder().decode(
                        OperationEvent.self, from: Data(contentJSON.utf8))
                else { return nil }
                return (entry.entryId, decoded)
            }
        }
    }

    // MARK: - The completion lands without another prompt

    @Test("a settled run's .completed event becomes a .toolOutput entry carrying its completion token as a parent reference, with no further prompt")
    @MainActor
    func settledRunLandsAsCorrelatedToolOutputEntry() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        // One turn, so the session is live and its journal is attached — the
        // state a run can only be parked from.
        _ = try await session.respond(to: "start the long job")

        let token = "01AN4Z07BY79KA1307SR9X4MV3"
        let terminal = OperationEvent(
            tool: "shell", op: "run command", correlationID: token, kind: .completed,
            detail: "exit 0, 2481 lines", outcome: .succeeded)
        await session.outbox.post(event: terminal)

        // No second prompt is sent: the transcript must already hold the
        // outcome.
        let journaled = Self.journaledRunEvents(in: await recorder.events)
        #expect(journaled.count == 1)
        // The entry id is the entry's own identity, which Apple documents
        // `Transcript.ToolOutput.id` as ("A unique id for this tool output"),
        // so it is never the run's completion token. The parent reference —
        // the token the model was handed — travels in the typed payload.
        let entryId = try #require(journaled.first?.entryId)
        #expect(entryId != token)
        #expect(!entryId.isEmpty)
        #expect(journaled.first?.event.correlationID == token)
        #expect(journaled.first?.event == terminal)

        let toolOutput = try #require((await recorder.events).first { $0.kind == .toolOutput })
        #expect(toolOutput.entry?.toolName == "shell")
        #expect(toolOutput.text == OperationEventSegment.renderedLine(for: terminal))
    }

    // MARK: - Order is the record, and progress is not coalesced

    @Test("every posted event of one run is journaled, in post order, with no progress coalescing")
    @MainActor
    func everyPostedEventIsJournaledInPostOrder() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "start the long job")

        let posted = [
            Self.event(kind: .progress, detail: "10%"),
            Self.event(kind: .progress, detail: "50%"),
            Self.event(kind: .completed, detail: "exit 0"),
        ]
        for event in posted {
            await session.outbox.post(event: event)
        }

        // The outbox coalesces the two `.progress` posts down to one pending
        // item, but the transcript keeps both: coalescing is a prompt-composition
        // policy over still-pending items, never a rewrite of what was appended.
        let pending = await session.outbox.pending()
        #expect(pending.events.count == 2)
        let journaled = Self.journaledRunEvents(in: await recorder.events)
        #expect(journaled.map(\.event) == posted)
        // One lifecycle is many entries, each with its own identity: the three
        // reports share one parent reference but never one entry id.
        #expect(Set(journaled.map(\.entryId)).count == posted.count)
        #expect(Set(journaled.map(\.event.correlationID)).count == 1)
    }

    // MARK: - The model still receives the outcome

    @Test("a journaled completion still rides the next turn's prompt as a preamble line and a .prompt segment")
    @MainActor
    func journaledCompletionStillReachesTheModel() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "start the long job")

        let terminal = Self.event(kind: .completed, detail: "exit 0, 2481 lines")
        await session.outbox.post(event: terminal)

        _ = try await session.respond(to: "what happened?")

        let events = await recorder.events
        let promptEvents = events.filter { $0.kind == .prompt }
        #expect(promptEvents.count == 2)
        let expectedLine = OperationEventSegment.renderedLine(for: terminal)
        #expect(promptEvents[1].text == expectedLine + "\n\nwhat happened?")
        #expect(promptEvents[1].entry?.segments?.count == 2)
    }

    // MARK: - The pre-first-turn boundary

    @Test("an event posted before the session's first turn is journaled by the turn it rides, not at post time")
    @MainActor
    func eventPostedBeforeTheFirstTurnIsJournaledByTheTurnItRides() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The restore path posts manufactured `.lost` terminals onto a fresh
        // outbox before the session has ever run a turn (see
        // `TranscriptTree.lostRunTerminalEvents(in:)`). A session that never
        // generates must still write no file at all, so nothing is journaled
        // here.
        await session.outbox.post(event: Self.event(kind: .completed, detail: "lost"))
        #expect(await recorder.events.isEmpty)

        _ = try await session.respond(to: "what happened?")
        #expect(Self.journaledRunEvents(in: await recorder.events).isEmpty)
        let promptEvent = try #require((await recorder.events).first { $0.kind == .prompt })
        #expect(promptEvent.entry?.segments?.count == 2)
    }

    // MARK: - One run, one recorded ending

    /// How long a test canceler waits for the run it just cancelled to settle.
    ///
    /// Generous, because it bounds a handshake the test itself drives to
    /// completion rather than a real cancellation: the wait resolves as soon as
    /// the mailbox marks the run settled, and the ceiling only exists so a
    /// broken handshake ends the test instead of hanging the suite.
    private static let settlementWaitSeconds: Double = 5

    /// Every journaled terminal (`.completed`) event recorded for one run.
    ///
    /// - Parameters:
    ///   - token: The run's completion token, which is its events' correlation
    ///     id.
    ///   - events: The recorded events to scan.
    /// - Returns: The run's journaled terminal events, in recorded order.
    private static func journaledTerminals(
        forRun token: String, in events: [TranscriptEvent]
    ) -> [OperationEvent] {
        journaledRunEvents(in: events)
            .map(\.event)
            .filter { $0.correlationID == token && $0.kind == .completed }
    }

    @Test("a run that settles inside sweep()'s canceler window is journaled once, not once live and again at close")
    @MainActor
    func aRunSettlingInsideTheCancelerWindowIsJournaledOnce() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "start the long job")

        let token = SessionMailbox.makeCompletionToken()
        let natural = OperationEvent(
            tool: "shell", op: "run command", correlationID: token, kind: .completed,
            detail: "exit 0, 2481 lines", outcome: .succeeded)

        // The run's body ends only once cancellation is requested, and posts its
        // own terminal through the outbox — journaling it live — before it ends.
        let cancelRequested = AsyncSemaphore(value: 0)
        let outbox = session.outbox
        let mailbox = session.mailbox
        let settling = Task { () -> OperationEvent in
            await cancelRequested.wait()
            await outbox.post(event: natural)
            return natural
        }
        await mailbox.park(
            tool: "shell",
            op: "run command",
            kind: .swiftTask,
            completionToken: token,
            settling: settling,
            canceler: {
                cancelRequested.signal()
                // Returning only once the mailbox has retained the natural
                // terminal is what holds `sweep()` inside the window it
                // suspends across, so the race is run rather than hoped for.
                _ = await mailbox.wait(
                    completionToken: token, seconds: Self.settlementWaitSeconds)
                return .cancelled
            })

        await session.close()

        // `sweep()` hands back the natural terminal it found retained, which is
        // the very event already journaled at post time. Recording it again
        // would say one run ended twice.
        let terminals = Self.journaledTerminals(forRun: token, in: await recorder.events)
        #expect(terminals.count == 1)
        #expect(terminals.first?.outcome == .succeeded)
    }

    @Test("a swept run that finishes cooperatively afterwards does not journal a second, contradicting terminal")
    @MainActor
    func aSweptRunFinishingAfterwardsJournalsNoSecondTerminal() async throws {
        let recorder = InMemoryRecorder()
        let (session, dir) = try await Self.makeSession(recorder: recorder)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try await session.respond(to: "start the long job")

        let token = SessionMailbox.makeCompletionToken()
        // Cancelling a `.swiftTask` run is cooperative: the canceler only
        // requests it, so the body is still running when the sweep synthesizes
        // its terminal.
        let bodyMayEnd = AsyncSemaphore(value: 0)
        let settling = Task { () -> OperationEvent in
            await bodyMayEnd.wait()
            return OperationEvent(
                tool: "shell", op: "run command", correlationID: token, kind: .completed,
                detail: "exit 0", outcome: .succeeded)
        }
        await session.mailbox.park(
            tool: "shell",
            op: "run command",
            kind: .swiftTask,
            completionToken: token,
            settling: settling,
            canceler: { .cancelled })

        await session.close()

        // The run finishes after the sweep and reports success — the opposite
        // outcome to the `.cancelled` terminal the sweep already recorded. Two
        // contradictory endings for one call is what a parent-grouping view
        // would draw, so the second report must not reach the transcript.
        await session.outbox.post(
            event: OperationEvent(
                tool: "shell", op: "run command", correlationID: token, kind: .completed,
                detail: "exit 0", outcome: .succeeded))
        bodyMayEnd.signal()
        _ = await settling.value

        let terminals = Self.journaledTerminals(forRun: token, in: await recorder.events)
        #expect(terminals.count == 1)
        #expect(terminals.first?.outcome == .cancelled)
    }
}
