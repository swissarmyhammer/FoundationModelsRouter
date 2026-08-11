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

    @Test("a settled run's .completed event becomes a .toolOutput entry keyed by its completion token, with no further prompt")
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
        await session.outbox.post(terminal)

        // No second prompt is sent: the transcript must already hold the
        // outcome.
        let journaled = Self.journaledRunEvents(in: await recorder.events)
        #expect(journaled.count == 1)
        #expect(journaled.first?.entryId == token)
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
            await session.outbox.post(event)
        }

        // The outbox coalesces the two `.progress` posts down to one pending
        // item, but the transcript keeps both: coalescing is a prompt-composition
        // policy over still-pending items, never a rewrite of what was appended.
        let pending = await session.outbox.pending()
        #expect(pending.events.count == 2)
        #expect(Self.journaledRunEvents(in: await recorder.events).map(\.event) == posted)
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
        await session.outbox.post(terminal)

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
        await session.outbox.post(Self.event(kind: .completed, detail: "lost"))
        #expect(await recorder.events.isEmpty)

        _ = try await session.respond(to: "what happened?")
        #expect(Self.journaledRunEvents(in: await recorder.events).isEmpty)
        let promptEvent = try #require((await recorder.events).first { $0.kind == .prompt })
        #expect(promptEvent.entry?.segments?.count == 2)
    }
}
