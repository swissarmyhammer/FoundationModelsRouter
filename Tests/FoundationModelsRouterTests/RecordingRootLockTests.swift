import Foundation
import Testing

@testable import FoundationModelsRouter

/// Exercises the recording-root writer guard: one live ``JSONLRecorder`` owns
/// a recording root at a time, a second owner gets the typed
/// ``RecordingRootLockError/alreadyOwned(root:owner:)`` at open time, a
/// non-owning writer drops its events instead of interleaving, a stale lock
/// marker left by a dead process is taken over, and a recorder that shuts
/// down cleanly releases the root.
@Suite("Recording root lock: one live writer per root")
struct RecordingRootLockTests {
    /// The lock marker's URL inside `root`.
    private static func lockFileURL(under root: URL) -> URL {
        root.appendingPathComponent(recordingRootLockFileName, isDirectory: false)
    }

    /// One stamped-and-appended event on `recorder`, targeting the recorder's
    /// own default directory.
    private static func appendEvent(
        _ kind: TranscriptEvent.Kind,
        on recorder: JSONLRecorder
    ) async {
        await recorder.append(
            TranscriptEvent.Partial(routerId: ULID(), sessionId: ULID(), kind: kind),
            to: nil
        )
    }

    /// The decoded events in `root`'s own `transcript.jsonl`, in file order.
    private static func recordedEvents(under root: URL) throws -> [TranscriptEvent] {
        let data = try Data(contentsOf: root.appendingPathComponent("transcript.jsonl", isDirectory: false))
        let decoder = JSONDecoder()
        return try data.split(separator: jsonlNewlineByte).map {
            try decoder.decode(TranscriptEvent.self, from: Data($0))
        }
    }

    @Test("a second owning recorder on the same root throws a typed error naming the live owner")
    func secondOwnerThrowsTypedErrorNamingOwner() throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try JSONLRecorder(owningDirectory: root)

        try withExtendedLifetime(first) {
            do {
                _ = try JSONLRecorder(owningDirectory: root)
                Issue.record("opening a second owning recorder on an owned root succeeded")
            } catch RecordingRootLockError.alreadyOwned(let lockedRoot, let owner) {
                #expect(lockedRoot.standardizedFileURL.path == root.standardizedFileURL.path)
                #expect(owner.processId == ProcessInfo.processInfo.processIdentifier)
            }
        }
    }

    @Test("a recorder that acquired the root lazily at first write also blocks a later owning recorder")
    func lazyFirstWriterBlocksLaterOwner() async throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWriter = JSONLRecorder(directory: root)
        await Self.appendEvent(.session, on: firstWriter)

        try withExtendedLifetime(firstWriter) {
            do {
                _ = try JSONLRecorder(owningDirectory: root)
                Issue.record("opening an owning recorder on a lazily claimed root succeeded")
            } catch RecordingRootLockError.alreadyOwned(_, let owner) {
                #expect(owner.processId == ProcessInfo.processInfo.processIdentifier)
            }
        }
    }

    @Test("a second non-owning recorder drops its events instead of interleaving into the owned root")
    func secondWriterDropsInsteadOfInterleaving() async throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }
        let firstWriter = JSONLRecorder(directory: root)
        await Self.appendEvent(.session, on: firstWriter)
        await Self.appendEvent(.response, on: firstWriter)

        let secondWriter = JSONLRecorder(directory: root)
        await Self.appendEvent(.session, on: secondWriter)
        await Self.appendEvent(.response, on: secondWriter)

        try withExtendedLifetime(firstWriter) {
            let events = try Self.recordedEvents(under: root)
            #expect(events.map(\.seq) == [0, 1])
            #expect(events.map(\.kind) == [.session, .response])
        }
    }

    @Test("a stale lock marker left by a dead process is taken over")
    func staleLockFromDeadProcessIsTakenOver() async throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }

        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        let staleOwner = RecordingRootOwner(processId: exited.processIdentifier, acquiredAt: Date())
        try JSONEncoder().encode(staleOwner).write(to: Self.lockFileURL(under: root))

        let recorder = try JSONLRecorder(owningDirectory: root)
        await Self.appendEvent(.session, on: recorder)

        try withExtendedLifetime(recorder) {
            let marker = try Data(contentsOf: Self.lockFileURL(under: root))
            let rewritten = try JSONDecoder().decode(RecordingRootOwner.self, from: marker)
            #expect(rewritten.processId == ProcessInfo.processInfo.processIdentifier)
            let events = try Self.recordedEvents(under: root)
            #expect(events.map(\.seq) == [0])
        }
    }

    @Test("a torn, undecodable lock marker is treated as stale and taken over")
    func tornLockMarkerIsTakenOver() throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not json".utf8).write(to: Self.lockFileURL(under: root))

        let recorder = try JSONLRecorder(owningDirectory: root)

        try withExtendedLifetime(recorder) {
            let marker = try Data(contentsOf: Self.lockFileURL(under: root))
            let rewritten = try JSONDecoder().decode(RecordingRootOwner.self, from: marker)
            #expect(rewritten.processId == ProcessInfo.processInfo.processIdentifier)
        }
    }

    @Test("clean shutdown releases the root: the marker is removed and a new owner succeeds")
    func cleanShutdownReleasesTheRoot() async throws {
        let root = RouterTestFixtures.makeTempDir(prefix: "RecordingRootLockTests")
        defer { try? FileManager.default.removeItem(at: root) }

        var recorder: JSONLRecorder? = try JSONLRecorder(owningDirectory: root)
        if let recorder {
            await Self.appendEvent(.session, on: recorder)
        }
        recorder = nil

        #expect(!FileManager.default.fileExists(atPath: Self.lockFileURL(under: root).path))
        let successor = try JSONLRecorder(owningDirectory: root)
        try withExtendedLifetime(successor) {
            let marker = try Data(contentsOf: Self.lockFileURL(under: root))
            let rewritten = try JSONDecoder().decode(RecordingRootOwner.self, from: marker)
            #expect(rewritten.processId == ProcessInfo.processInfo.processIdentifier)
        }
    }
}
