import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// No limit on the sessions that work at the same time (ROUTER-5, D72): no
/// start and no delivery waits for a free slot. The old limit of four came
/// from the subagent cap of FoundationModelsAgents.
///
/// The test starts six sessions through a ``FakeSessionLauncher`` and holds
/// the first model call of each, so all six work at once.
@Suite("RouterSessionDirectory: no cap on the sessions that work at the same time")
struct RouterSessionDirectoryNoCapTests {
    /// Vends a new ``SessionMessagePumpTests/PumpProbeBackend`` for each
    /// session, whose first call holds on one latch that the test opens.
    struct HeldBackendsContainer: LoadedLLMContainer {
        /// The scripted counter of this container: one token per `Character`.
        let tokenCounter: any TokenCounter = CharacterTokenCounter()

        /// The latch that holds the first call of each backend.
        let latch: RunLatch

        /// Vends a backend whose first call holds on ``latch``.
        ///
        /// - Parameter instructions: The instructions of the session. Unread.
        /// - Returns: The backend.
        func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
            SessionMessagePumpTests.PumpProbeBackend(script: [RouterSessionDirectoryNoCapTests.firstCall: .hold(latch)])
        }

        /// Vends a backend seeded with `transcript`. No test restores.
        ///
        /// - Parameter transcript: The transcript to seed.
        /// - Returns: The backend.
        func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
            StubSessionBackend(entries: Array(transcript))
        }
    }

    // MARK: - Constants

    /// The number of the first call of a scripted backend.
    private static let firstCall = 1

    /// More sessions than the old limit of four sessions that work at the
    /// same time.
    private static let sessionCount = 6

    /// The UI client that sends each message.
    private static let clientID = "client-a"

    /// The text of each first message.
    private static let text = "Please triage the open issues."

    // MARK: - Test

    /// The production change that makes this test fail: a limit on the
    /// sessions that work at the same time, which would hold a start, or
    /// queue its first message, until a slot is free.
    @Test("six sessions started through the launcher all work at the same time, no receipt is queued, and all answer")
    func sixSessionsWorkAtTheSameTime() async throws {
        let latch = RunLatch()
        let directories = TestDirectories(prefix: "RouterSessionDirectoryNoCapTests")
        let (router, profile) = try await RouterTestFixtures.resolveStandardProfile(
            over: HeldBackendsContainer(latch: latch), cacheDir: directories.cacheDir,
            recordingsDir: directories.recordingsDir)
        let launcher = FakeSessionLauncher(profile: profile)
        let directory = router.sessionDirectory
        await directory.use(launcher: launcher)
        var events = directory.events().makeAsyncIterator()

        var receipts: [SessionSendReceipt] = []
        for index in 0..<Self.sessionCount {
            receipts += try await directory.send(
                OutgoingSessionMessage(
                    from: .user(clientID: Self.clientID), to: .agent(id: "agent-\(index)", folder: nil), text: Self.text))
        }
        let ids = Set(receipts.compactMap(\.target))
        // Rule T1 quiet state: a directory that holds a session back for a
        // free slot never reports all six working while the latch is shut,
        // so the test hangs here and never passes.
        await Self.read(&events, until: .working, for: ids)
        let working = try await directory.sessions(matching: SessionQuery()).filter { ids.contains($0.id) }
        await latch.open()
        await Self.read(&events, until: .idle, for: ids)

        #expect(receipts.map(\.outcome) == Array(repeating: .started, count: Self.sessionCount))
        #expect(ids.count == Self.sessionCount)
        #expect(working.map(\.state) == Array(repeating: .working, count: Self.sessionCount))
        let answered = try await directory.sessions(matching: SessionQuery()).filter { ids.contains($0.id) }
        #expect(
            answered.map(\.lastSummary)
                == Array(repeating: SessionMessagePumpTests.PumpProbeBackend.answer(ofCall: Self.firstCall), count: Self.sessionCount))
        await launcher.closeSessions()
        directories.remove()
    }

    /// Reads the directory events until each session of `ids` changed to
    /// `state`.
    ///
    /// - Parameters:
    ///   - events: The iterator of the directory events.
    ///   - state: The state each session reaches.
    ///   - ids: The sessions.
    private static func read(
        _ events: inout AsyncStream<SessionDirectoryEvent>.Iterator, until state: SessionState, for ids: Set<ULID>
    ) async {
        var reached: Set<ULID> = []
        while reached != ids, let event = await events.next() {
            if case .stateChanged(let id, state, _) = event, ids.contains(id) {
                reached.insert(id)
            }
        }
    }
}
