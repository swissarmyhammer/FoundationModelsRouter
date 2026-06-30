import Foundation
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
    private static let fixedInstant = Date(timeIntervalSinceReferenceDate: 1_000.5)

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
                    await recorder.append(self.samplePartial(kind: .prompt))
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
            await recorder.append(samplePartial(kind: kind))
        }

        let fileURL = dir.appendingPathComponent("transcript.jsonl", isDirectory: false)
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)

        let decoder = JSONDecoder()
        let decoded = try lines.map {
            try decoder.decode(TranscriptEvent.self, from: Data($0.utf8))
        }
        #expect(decoded.map(\.seq) == [0, 1, 2])
        #expect(decoded.map(\.kind) == [.session, .prompt, .response])
        #expect(decoded.allSatisfy { $0.ts == Self.fixedInstant })
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
        await recorder.append(samplePartial(kind: .prompt))
        await recorder.append(samplePartial(kind: .response))

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
            await recorder.append(partial)
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
