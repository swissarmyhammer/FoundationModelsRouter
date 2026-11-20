import Foundation
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The JSON file store of the session usage (ROUTER-3): one ``SessionUsage``
/// for each session id, in one JSON file. A pin, an unpin and a last use go to
/// the file, and a new store that reads the same file gets them back. The
/// store keeps all the pinned entries and a maximum number of the entries that
/// are not pinned. A missing file and a damaged file give an empty store.
/// Each test makes its own temp folder and removes it in a `defer`.
@Suite struct JSONFileSessionUsageStoreTests {
    /// A temp folder and the file of the store in a subfolder that does not
    /// exist yet, so that the first write must make the subfolder.
    struct Fixture {
        /// The temp folder that holds all the other items.
        let root: URL

        /// The folder of the store file. The store makes it at its first
        /// write.
        let storeFolder: URL

        /// The file of the store.
        let fileURL: URL

        /// The recording root of the sessions of the tests.
        let recordingRoot: URL

        init() {
            root = RouterTestFixtures.makeTempDir(prefix: "JSONFileSessionUsageStoreTests")
            storeFolder = RouterTestFixtures.usageStoreFolder(in: root)
            fileURL = RouterTestFixtures.usageStoreURL(in: storeFolder)
            recordingRoot = root.appendingPathComponent("recordings", isDirectory: true)
        }

        /// Makes a store of ``fileURL``.
        ///
        /// - Parameter maximumRecentCount: The maximum number of the entries
        ///   that are not pinned.
        /// - Returns: A new store that has not read the file yet.
        func makeStore(
            maximumRecentCount: Int = JSONFileSessionUsageStore.defaultMaximumRecentCount
        ) -> JSONFileSessionUsageStore {
            RouterTestFixtures.makeUsageStore(in: storeFolder, maximumRecentCount: maximumRecentCount)
        }

        /// Writes `text` to ``fileURL`` in place of a valid store file.
        ///
        /// - Parameter text: The text of the file.
        func writeFile(_ text: String) throws {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: fileURL)
        }

        /// Removes the temp folder and all that it holds.
        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The time of the first event of a test.
    static let firstTime = Date(timeIntervalSince1970: 1_800_000_000)

    /// The interval between two events of a test.
    static let interval: TimeInterval = 60

    /// The text of a file that is not JSON.
    static let damagedText = "{ this is not json"

    /// A file version that no store knows.
    static let unknownVersion = 999

    /// The message of the `warning` record of a read of a damaged file.
    static let damagedFileWarning = "a session usage file cannot be read; the store starts empty"

    /// The time of the event at `index`, ``interval`` after the event before.
    ///
    /// - Parameter index: The index of the event, from 0.
    /// - Returns: The time.
    static func time(_ index: Int) -> Date {
        firstTime.addingTimeInterval(interval * TimeInterval(index))
    }

    // MARK: - Round trip

    /// A pin goes to the file, and a new store reads it back.
    @Test func aPinComesBackFromTheFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()

        try fixture.makeStore().setPinned(true, of: id, recordingRoot: fixture.recordingRoot, at: Self.time(0))

        #expect(
            fixture.makeStore().usage(of: id)
                == SessionUsage(pinnedAt: Self.time(0), lastUsedAt: nil, recordingRoot: fixture.recordingRoot))
    }

    /// A last use goes to the file, and a new store reads it back.
    @Test func aLastUseComesBackFromTheFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()

        try fixture.makeStore().markUsed(id, recordingRoot: fixture.recordingRoot, at: Self.time(0))

        #expect(
            fixture.makeStore().usage(of: id)
                == SessionUsage(pinnedAt: nil, lastUsedAt: Self.time(0), recordingRoot: fixture.recordingRoot))
    }

    /// An unpin goes to the file: a new store reads the entry with no pin and
    /// with its last use.
    @Test func anUnpinComesBackFromTheFile() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        let store = fixture.makeStore()

        try store.markUsed(id, recordingRoot: fixture.recordingRoot, at: Self.time(0))
        try store.setPinned(true, of: id, recordingRoot: nil, at: Self.time(1))
        try store.setPinned(false, of: id, recordingRoot: nil, at: Self.time(2))

        #expect(
            fixture.makeStore().usage(of: id)
                == SessionUsage(pinnedAt: nil, lastUsedAt: Self.time(0), recordingRoot: fixture.recordingRoot))
    }

    /// A time with a part of a millisecond comes back from the file equal to
    /// the usage that the write returned.
    @Test func aTimeWithAPartOfAMillisecondComesBackEqual() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()

        let written = try fixture.makeStore().markUsed(
            id, recordingRoot: fixture.recordingRoot,
            at: Self.time(0).addingTimeInterval(RouterTestFixtures.subMillisecond))

        #expect(fixture.makeStore().usage(of: id) == written)
    }

    // MARK: - Pins

    /// A second pin keeps the time of the first pin.
    @Test func aSecondPinKeepsTheFirstPinTime() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        let store = fixture.makeStore()

        try store.setPinned(true, of: id, recordingRoot: fixture.recordingRoot, at: Self.time(0))
        try store.setPinned(true, of: id, recordingRoot: nil, at: Self.time(1))

        #expect(fixture.makeStore().usage(of: id)?.pinnedAt == Self.time(0))
    }

    /// An unpin of a session that has no last use and no recording root
    /// removes its entry.
    @Test func anUnpinOfANeverUsedSessionRemovesTheEntry() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        let store = fixture.makeStore()

        try store.setPinned(true, of: id, recordingRoot: nil, at: Self.time(0))
        try store.setPinned(false, of: id, recordingRoot: nil, at: Self.time(1))

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// The production change that makes this test fail: an unpin that
    /// removes a usage with no last use, also when it holds a recording
    /// root, so the list no longer reads the root of the session.
    @Test func anUnpinKeepsTheRecordingRoot() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        let store = fixture.makeStore()

        try store.setRecordingRoot(fixture.recordingRoot, of: id)
        try store.setPinned(true, of: id, recordingRoot: nil, at: Self.time(0))
        try store.setPinned(false, of: id, recordingRoot: nil, at: Self.time(1))

        #expect(fixture.makeStore().usage(of: id) == SessionUsage(recordingRoot: fixture.recordingRoot))
    }

    // MARK: - Recording roots

    /// The production change that makes this test fail: a store that does
    /// not keep a usage that holds only a recording root.
    @Test func aRecordingRootComesBackWithNoUse() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()

        try fixture.makeStore().setRecordingRoot(fixture.recordingRoot, of: id)

        #expect(fixture.makeStore().usage(of: id) == SessionUsage(recordingRoot: fixture.recordingRoot))
    }

    /// The production change that makes this test fail: a limit that puts
    /// a usage with no last use before all the others, so the write of a
    /// recording root to a full store removes that usage at once.
    @Test func aboveTheLimitAUsageWithNoUseCountsFromTheTimeOfItsID() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let used = ULID()
        let recorded = ULID(timestamp: Self.time(1))
        let store = fixture.makeStore(maximumRecentCount: 1)

        try store.markUsed(used, recordingRoot: fixture.recordingRoot, at: Self.time(0))
        try store.setRecordingRoot(fixture.recordingRoot, of: recorded)

        #expect(Set(fixture.makeStore().usages().keys) == [recorded])
    }

    /// A `nil` recording root keeps the recording root that the store holds.
    @Test func aNilRecordingRootKeepsTheStoredRoot() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        let store = fixture.makeStore()

        try store.markUsed(id, recordingRoot: fixture.recordingRoot, at: Self.time(0))
        try store.markUsed(id, recordingRoot: nil, at: Self.time(1))

        #expect(fixture.makeStore().usage(of: id)?.recordingRoot == fixture.recordingRoot)
    }

    // MARK: - Limit

    /// Above the limit, the entry with the oldest last use goes.
    @Test func aboveTheLimitTheOldestEntryGoes() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let ids = [ULID(), ULID(), ULID()]
        let store = fixture.makeStore(maximumRecentCount: ids.count - 1)

        for (index, id) in ids.enumerated() {
            try store.markUsed(id, recordingRoot: fixture.recordingRoot, at: Self.time(index))
        }

        #expect(Set(fixture.makeStore().usages().keys) == Set(ids.dropFirst()))
    }

    /// Above the limit, a pinned entry stays, also when its last use is the
    /// oldest, and the oldest entry that is not pinned goes.
    @Test func aboveTheLimitAPinnedEntryStays() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let pinned = ULID()
        let older = ULID()
        let newer = ULID()
        let store = fixture.makeStore(maximumRecentCount: 1)

        try store.markUsed(pinned, recordingRoot: fixture.recordingRoot, at: Self.time(0))
        try store.setPinned(true, of: pinned, recordingRoot: nil, at: Self.time(1))
        try store.markUsed(older, recordingRoot: fixture.recordingRoot, at: Self.time(2))
        try store.markUsed(newer, recordingRoot: fixture.recordingRoot, at: Self.time(3))

        #expect(Set(fixture.makeStore().usages().keys) == [pinned, newer])
    }

    // MARK: - Missing and damaged files

    /// A missing file gives an empty store.
    @Test func aMissingFileGivesAnEmptyStore() {
        let fixture = Fixture()
        defer { fixture.remove() }

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// A damaged file gives an empty store.
    @Test func aDamagedFileGivesAnEmptyStore() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeFile(Self.damagedText)

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// A read of a damaged file writes one warning.
    @Test func aDamagedFileWritesOneWarning() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeFile(Self.damagedText)

        let warnings = try await TelemetryCapture.run(forbidding: []) { context in
            _ = fixture.makeStore().usages()
            return context.logRecords.filter {
                $0.level == .warning && "\($0.message)" == Self.damagedFileWarning
            }.count
        }

        #expect(warnings == 1)
    }

    /// A file of a version that the store does not know gives an empty store.
    @Test func aFileOfAnUnknownVersionGivesAnEmptyStore() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeFile(#"{"version":\#(Self.unknownVersion),"sessions":{}}"#)

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// A file with a session key that is not a ULID gives an empty store.
    @Test func aFileWithAKeyThatIsNotAULIDGivesAnEmptyStore() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeFile(
            #"{"version":\#(JSONFileSessionUsageStore.fileVersion),"sessions":{"not-a-ulid":{}}}"#)

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// A file entry with no pin, no last use and no recording root is not a
    /// usage: the read removes it, as a write does.
    @Test func aFileEntryThatHoldsNothingIsRemovedAtTheRead() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.writeFile(
            #"{"version":\#(JSONFileSessionUsageStore.fileVersion),"sessions":{"\#(ULID().ulidString)":{}}}"#)

        #expect(fixture.makeStore().usages().isEmpty)
    }

    /// A write after a damaged file replaces the file, and a new store reads
    /// the write back.
    @Test func aWriteAfterADamagedFileComesBack() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let id = ULID()
        try fixture.writeFile(Self.damagedText)

        try fixture.makeStore().markUsed(id, recordingRoot: fixture.recordingRoot, at: Self.time(0))

        #expect(
            fixture.makeStore().usage(of: id)
                == SessionUsage(pinnedAt: nil, lastUsedAt: Self.time(0), recordingRoot: fixture.recordingRoot))
    }
}
