import Foundation
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Tests for the recording substrate — ``TranscriptEvent``, the
/// ``TranscriptRecorder`` protocol, and its three sinks (``InMemoryRecorder``,
/// ``JSONLRecorder``, ``NoneRecorder``).
///
/// The recorder is the plumbing a session is *born holding*: every sink shares
/// one append path, and the recorder — not the caller — stamps `seq` and `ts`
/// at append, so concurrent appends produce a single totally-ordered log.
///
/// The concurrency assertion is deterministic, not timing-based: because the
/// recorder is an actor, the `seq` it stamps and the order it stores events in
/// are assigned in the same critical section, so the stored `seq` sequence must
/// be exactly `0..<n` regardless of how the tasks were scheduled.
@Suite("Recorder")
struct RecorderTests {
    /// A fixed instant so stamped timestamps are deterministic in assertions.
    /// It falls on a whole millisecond, because a transcript line keeps its
    /// `ts` to the millisecond.
    private static let fixedInstant = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The first stamp of the sub-second test, in milliseconds since 1970: a
    /// time inside a second, not at its start.
    private static let subSecondStartMilliseconds: Int64 = 1_792_000_000_123

    /// The gap between the two stamps of the sub-second test, in
    /// milliseconds: less than one second.
    private static let subSecondGapMilliseconds: Int64 = 10

    /// A clock that gives the instants of a list in turn, one for each call.
    private final class InstantSequence: Sendable {
        /// The instants that the next calls give, in order.
        private let remaining: Mutex<[Date]>

        /// Makes a clock over `instants`.
        ///
        /// - Parameter instants: The instants, in the order the calls get them.
        init(_ instants: [Date]) {
            remaining = Mutex(instants)
        }

        /// The next instant of the list.
        ///
        /// - Returns: The first instant that no earlier call got.
        func next() -> Date {
            remaining.withLock { $0.removeFirst() }
        }
    }

    /// Builds a sample partial event with the given kind; provenance ids are
    /// fresh ULIDs and the optional metering fields are populated.
    private func samplePartial(kind: TranscriptEvent.Kind) -> TranscriptEvent.Partial {
        TranscriptEvent.Partial(
            routerId: ULID.generate(),
            sessionId: ULID.generate(),
            parentId: ULID.generate(),
            slot: .standard,
            model: ModelRef("org/repo@rev"),
            kind: kind,
            grammar: "json",
            tokensIn: 3,
            tokensOut: 5,
            ms: 7
        )
    }

    @Test("inMemory stamps a contiguous, monotonic seq under concurrent appends")
    func inMemoryTotalOrdering() async {
        let recorder: InMemoryRecorder = .inMemory
        let n = 500

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<n {
                group.addTask {
                    await recorder.append(self.samplePartial(kind: .prompt), to: nil)
                }
            }
        }

        let events = await recorder.events
        #expect(events.count == n)
        // Stored order == seq order == 0,1,2,... with no gaps or duplicates.
        #expect(events.map(\.seq) == Array(0..<n))
    }

    @Test("jsonl writes one JSON object per line, seq-ordered, with the injected clock")
    func jsonlLinePerEvent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let recorder: JSONLRecorder = .jsonl(
            directory: dir,
            now: { Self.fixedInstant }
        )
        for kind in [TranscriptEvent.Kind.session, .prompt, .response] {
            await recorder.append(samplePartial(kind: kind), to: nil)
        }

        let fileURL = dir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let lines = try TextFileLines.read(from: fileURL)
        #expect(lines.count == 3)

        let decoder = JSONLines.makeDecoder()
        let decoded = try lines.map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
        #expect(decoded.map(\.seq) == [0, 1, 2])
        #expect(decoded.map(\.kind) == [.session, .prompt, .response])
        #expect(decoded.allSatisfy { $0.ts == Self.fixedInstant })
    }

    /// The production change that makes this test fail: a `transcript.jsonl`
    /// line that keeps its `ts` to the whole second, so both events read back
    /// with one `ts` and lose their order in time.
    @Test("jsonl keeps two events 10 ms apart in order, each with its own ts")
    func jsonlKeepsSubSecondTimestamps() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = DateTime(millisecondsSince1970: Self.subSecondStartMilliseconds).date
        let second = DateTime(
            millisecondsSince1970: Self.subSecondStartMilliseconds + Self.subSecondGapMilliseconds
        ).date
        let clock = InstantSequence([first, second])
        let recorder: JSONLRecorder = .jsonl(directory: dir, now: { clock.next() })

        await recorder.append(samplePartial(kind: .prompt), to: nil)
        await recorder.append(samplePartial(kind: .response), to: nil)

        let fileURL = dir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let events = try JSONLFile(url: fileURL).records(as: TranscriptEvent.self)
        #expect(events.map(\.kind) == [.prompt, .response])
        #expect(events.map(\.ts) == [first, second])
    }

    @Test("jsonl swallows a forced write error instead of throwing")
    func jsonlSwallowsWriteError() async throws {
        // A regular file standing where the recorder's directory should be:
        // every append's directory-create fails, so the write must be swallowed.
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }

        let recorder: JSONLRecorder = .jsonl(directory: blocker)
        // Must return normally (non-throwing) and never crash.
        await recorder.append(samplePartial(kind: .prompt), to: nil)
        await recorder.append(samplePartial(kind: .response), to: nil)

        // The blocking file is untouched: nothing was written through it.
        let attributes = try FileManager.default.attributesOfItem(atPath: blocker.path)
        #expect((attributes[.type] as? FileAttributeType) == .typeRegular)
        #expect(try Data(contentsOf: blocker).isEmpty)
    }

    @Test("none is a no-op that shares the identical call path")
    func noneRecordsNothing() async {
        // Bound as the protocol existential so the appends go through the shared
        // `TranscriptRecorder` call path, not NoneRecorder's concrete type.
        let recorder: any TranscriptRecorder = NoneRecorder.none
        for partial in [samplePartial(kind: .prompt), samplePartial(kind: .response)] {
            await recorder.append(partial, to: nil)
        }
        // A no-op sink keeps no state; the call simply completes.
    }

    @Test("TranscriptEvent round-trips all provenance fields through Codable")
    func codableRoundTripFull() throws {
        let event = TranscriptEvent(
            routerId: ULID.generate(),
            sessionId: ULID.generate(),
            parentId: ULID.generate(),
            slot: .embedding,
            model: ModelRef("mlx-community/Model@main"),
            seq: 42,
            ts: Self.fixedInstant,
            kind: .toolCall,
            grammar: "regex:[0-9]+",
            tokensIn: 11,
            tokensOut: 22,
            ms: 33
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("TranscriptEvent round-trips when its optional provenance fields are nil")
    func codableRoundTripMinimal() throws {
        let event = TranscriptEvent(
            routerId: ULID.generate(),
            sessionId: ULID.generate(),
            parentId: nil,
            slot: nil,
            model: nil,
            seq: 0,
            ts: Self.fixedInstant,
            kind: .session,
            grammar: nil,
            tokensIn: nil,
            tokensOut: nil,
            ms: nil
        )

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(TranscriptEvent.self, from: data)
        #expect(decoded == event)
    }
}
