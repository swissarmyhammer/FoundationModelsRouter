import Foundation
import FoundationModelsExtras
import Logging
import TelemetryTestSupport
import Testing

@testable import FoundationModelsRouter

/// The project store: a folder the host gives, with one
/// `<sha256 of the path>.md` file for each project. Each file holds a
/// ``ProjectRecord`` as YAML frontmatter. An update rewrites only its own
/// file, a remove deletes only its own file, and a listing skips each file it
/// cannot read with a warning. Every test builds its own throwaway store
/// folder and project folders under a temp directory.
@Suite struct ProjectStoreTests {
    /// A throwaway store folder plus real project folders, so the stale-skip
    /// check can delete one.
    struct Fixture {
        /// The temp root that holds every other folder.
        let root: URL

        /// The store folder the host gives. A fixture does not create it.
        let storeDirectory: URL

        /// The store under test.
        let store: ProjectStore

        init() {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ProjectStoreTests-\(UUID().uuidString)", isDirectory: true)
            storeDirectory = root.appendingPathComponent("projects", isDirectory: true)
            store = ProjectStore(directory: storeDirectory)
        }

        /// Makes a real project folder named `name`.
        ///
        /// - Parameter name: The name of the folder.
        /// - Returns: The folder URL.
        func makeProjectDirectory(named name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// The file of the project at `project` in the store folder.
        ///
        /// - Parameter project: The project folder.
        /// - Returns: The file URL.
        func file(of project: URL) -> URL {
            storeDirectory.appendingPathComponent(
                ProjectStore.fileName(forWorkingDirectory: project), isDirectory: false)
        }

        /// The names of the entries of the store folder, sorted.
        ///
        /// - Returns: The names.
        func storeFileNames() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: storeDirectory.path).sorted()
        }

        /// Writes `text` to the file `name` in the store folder, and creates
        /// the folder when it is absent.
        ///
        /// - Parameters:
        ///   - text: The text of the file.
        ///   - name: The name of the file.
        func writeStoreFile(_ text: String, named name: String) throws {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            try text.write(
                to: storeDirectory.appendingPathComponent(name, isDirectory: false), atomically: true,
                encoding: .utf8)
        }
    }

    /// The instant of the first visit in each test.
    static let firstVisit = Date(timeIntervalSince1970: 1_756_000_000)

    /// A later instant, for the revisit tests.
    static let secondVisit = Date(timeIntervalSince1970: 1_756_100_000)

    /// ``firstVisit`` as the frontmatter writes it.
    static let firstVisitText = "2025-08-24T01:46:40.000Z"

    /// A body a host writes below the frontmatter of a project file.
    static let hostBody = "# Notes\n\nThe host keeps its notes here.\n"

    /// The message of the `warning` record a listing writes when it skips a
    /// file.
    static let skippedFileWarning = "skipped a project file that does not hold a project record"

    // MARK: - One file per project

    /// Two projects give two files, each named by the hash of its own path.
    @Test func twoProjectsGiveTwoFiles() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        let beta = try fixture.makeProjectDirectory(named: "beta")

        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        try fixture.store.register(workingDirectory: beta, at: Self.secondVisit)

        let expected = [alpha, beta].map(ProjectStore.fileName(forWorkingDirectory:)).sorted()
        #expect(try fixture.storeFileNames() == expected)
    }

    /// An update of one project rewrites its own file, keeps its
    /// `firstSeen`, moves its `lastSeen`, and leaves the file of the other
    /// project byte for byte.
    @Test func anUpdateTouchesOnlyItsOwnFile() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        let beta = try fixture.makeProjectDirectory(named: "beta")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        try fixture.store.register(workingDirectory: beta, at: Self.firstVisit)
        let betaBefore = try Data(contentsOf: fixture.file(of: beta))
        let alphaBefore = try Data(contentsOf: fixture.file(of: alpha))

        try fixture.store.register(workingDirectory: alpha, at: Self.secondVisit)

        #expect(try Data(contentsOf: fixture.file(of: beta)) == betaBefore)
        #expect(try Data(contentsOf: fixture.file(of: alpha)) != alphaBefore)
        #expect(
            try fixture.store.projects() == [
                ProjectRecord(path: alpha.standardizedFileURL.path, firstSeen: Self.firstVisit, lastSeen: Self.secondVisit),
                ProjectRecord(path: beta.standardizedFileURL.path, firstSeen: Self.firstVisit, lastSeen: Self.firstVisit),
            ])
    }

    /// A remove deletes the file of its project, and only that file.
    @Test func aRemoveDeletesOnlyItsOwnFile() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        let beta = try fixture.makeProjectDirectory(named: "beta")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        try fixture.store.register(workingDirectory: beta, at: Self.firstVisit)

        try fixture.store.remove(workingDirectory: alpha)

        #expect(try fixture.storeFileNames() == [ProjectStore.fileName(forWorkingDirectory: beta)])
        #expect(try fixture.store.projects().map(\.path) == [beta.standardizedFileURL.path])
    }

    /// A remove of a project the store does not hold is no error.
    @Test func aRemoveOfAnUnknownProjectIsNoError() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.store.remove(workingDirectory: alpha)

        #expect(try fixture.store.projects().isEmpty)
    }

    /// The same path always gives the same file name: the lowercase hex
    /// SHA-256 of the standardized path, then `.md`. A trailing `/` and a `.`
    /// component name the same project.
    @Test func theSamePathAlwaysGivesTheSameFileName() {
        let expected = "1800429f9dcb5572414612eca94316ff6582214b4b56ed64ddb562101830c6dd.md"
        let spellings = [
            URL(fileURLWithPath: "/Users/dev/projects/alpha", isDirectory: false),
            URL(fileURLWithPath: "/Users/dev/projects/alpha/", isDirectory: true),
            URL(fileURLWithPath: "/Users/dev/projects/./alpha", isDirectory: true),
        ]

        #expect(spellings.map(ProjectStore.fileName(forWorkingDirectory:)) == Array(repeating: expected, count: 3))
    }

    /// A register creates the store folder when the host has not.
    @Test func aRegisterCreatesTheStoreFolder() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)

        #expect(try fixture.storeFileNames() == [ProjectStore.fileName(forWorkingDirectory: alpha)])
    }

    // MARK: - The file format

    /// The file is markdown whose frontmatter holds the path and both dates
    /// as ISO 8601 text with milliseconds.
    @Test func theFrontmatterHoldsThePathAndMillisecondDates() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")

        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)

        let text = try String(contentsOf: fixture.file(of: alpha), encoding: .utf8)
        let frontmatter = try #require(FrontmatterDocument.split(text: text).frontmatter)
        #expect(
            try YAMLValue.parse(frontmatter)
                == .dictionary([
                    "path": .string(alpha.standardizedFileURL.path),
                    "firstSeen": .string(Self.firstVisitText),
                    "lastSeen": .string(Self.firstVisitText),
                ]))
    }

    /// A date inside a millisecond reads back rounded to the millisecond, the
    /// precision of the text.
    @Test func aDateReadsBackAtMillisecondPrecision() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        let instant = Date(timeIntervalSince1970: 1_756_000_000.123_456)

        try fixture.store.register(workingDirectory: alpha, at: instant)

        let read = try #require(try fixture.store.projects().first)
        #expect(read.firstSeen == MillisecondDate.rounded(instant))
        #expect(read.lastSeen == MillisecondDate.rounded(instant))
    }

    /// An update keeps the body a host wrote below the frontmatter.
    @Test func anUpdateKeepsTheBody() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        let file = fixture.file(of: alpha)
        try (try String(contentsOf: file, encoding: .utf8) + Self.hostBody)
            .write(to: file, atomically: true, encoding: .utf8)

        try fixture.store.register(workingDirectory: alpha, at: Self.secondVisit)

        #expect(FrontmatterDocument.split(text: try String(contentsOf: file, encoding: .utf8)).body == Self.hostBody)
    }

    // MARK: - The listing

    /// A store folder that does not exist lists no projects, not an error.
    @Test func aMissingStoreFolderListsNoProjects() throws {
        let fixture = Fixture()

        #expect(try fixture.store.projects().isEmpty)
    }

    /// A project whose folder no longer exists is stale: the listing skips
    /// it and keeps the live ones.
    @Test func aStaleProjectIsSkipped() throws {
        let fixture = Fixture()
        let kept = try fixture.makeProjectDirectory(named: "alpha")
        let removed = try fixture.makeProjectDirectory(named: "beta")
        try fixture.store.register(workingDirectory: kept, at: Self.firstVisit)
        try fixture.store.register(workingDirectory: removed, at: Self.secondVisit)
        try FileManager.default.removeItem(at: removed)

        #expect(try fixture.store.projects().map(\.path) == [kept.standardizedFileURL.path])
    }

    /// The listing gives the projects by `firstSeen`, the earliest first.
    @Test func theListingIsOrderedByFirstSeen() throws {
        let fixture = Fixture()
        let later = try fixture.makeProjectDirectory(named: "alpha")
        let earlier = try fixture.makeProjectDirectory(named: "beta")
        try fixture.store.register(workingDirectory: later, at: Self.secondVisit)
        try fixture.store.register(workingDirectory: earlier, at: Self.firstVisit)

        #expect(
            try fixture.store.projects().map(\.path) == [earlier, later].map(\.standardizedFileURL.path))
    }

    /// A file that is not `.md` is not a project file: the listing ignores
    /// it and writes no warning.
    @Test func aFileThatIsNotMarkdownIsIgnoredWithNoWarning() async throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        try fixture.writeStoreFile("not a project", named: "notes.txt")
        try fixture.writeStoreFile("not a project", named: ".\(ProjectStore.fileName(forWorkingDirectory: alpha)).icloud")

        let (paths, warnings) = try await Self.listing(of: fixture.store, forbidding: [alpha])

        #expect(paths == [alpha.standardizedFileURL.path])
        #expect(warnings == 0)
    }

    /// A `.md` file whose frontmatter does not decode is skipped with one
    /// warning, and the listing still gives every other project.
    @Test func anUndecodableFileIsSkippedWithOneWarning() async throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        try fixture.writeStoreFile("---\npath: [unclosed\n---\n", named: "broken.md")

        let (paths, warnings) = try await Self.listing(of: fixture.store, forbidding: [alpha])

        #expect(paths == [alpha.standardizedFileURL.path])
        #expect(warnings == 1)
    }

    /// A `.md` file with no frontmatter, such as a partial download, is
    /// skipped with one warning.
    @Test func aFileWithNoFrontmatterIsSkippedWithOneWarning() async throws {
        let fixture = Fixture()
        try fixture.writeStoreFile("", named: "empty.md")

        let (paths, warnings) = try await Self.listing(of: fixture.store, forbidding: [])

        #expect(paths.isEmpty)
        #expect(warnings == 1)
    }

    /// A conflict copy, a file whose record decodes but whose name is not the
    /// hash of its own path, is skipped with one warning, so the project is
    /// listed once.
    @Test func aConflictCopyIsSkippedWithOneWarning() async throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        let text = try String(contentsOf: fixture.file(of: alpha), encoding: .utf8)
        let name = ProjectStore.fileName(forWorkingDirectory: alpha)
        try fixture.writeStoreFile(text, named: name.replacingOccurrences(of: ".md", with: " 2.md"))

        let (paths, warnings) = try await Self.listing(of: fixture.store, forbidding: [alpha])

        #expect(paths == [alpha.standardizedFileURL.path])
        #expect(warnings == 1)
    }

    /// The name of a project file matches with no regard to case, as the
    /// file system of the host does: an upper case name of the right hash
    /// is the project's file.
    @Test func anUpperCaseFileNameIsTheProjectsFile() async throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.store.register(workingDirectory: alpha, at: Self.firstVisit)
        let file = fixture.file(of: alpha)
        let text = try String(contentsOf: file, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try fixture.writeStoreFile(text, named: ProjectStore.fileName(forWorkingDirectory: alpha).uppercased())

        let (paths, warnings) = try await Self.listing(of: fixture.store, forbidding: [alpha])

        #expect(paths == [alpha.standardizedFileURL.path])
        #expect(warnings == 0)
    }

    /// A register over a file that does not decode writes a fresh record in
    /// its place, with `firstSeen` at the register.
    @Test func aRegisterOverAnUndecodableFileWritesAFreshRecord() throws {
        let fixture = Fixture()
        let alpha = try fixture.makeProjectDirectory(named: "alpha")
        try fixture.writeStoreFile("---\npath: [unclosed\n---\n", named: ProjectStore.fileName(forWorkingDirectory: alpha))

        try fixture.store.register(workingDirectory: alpha, at: Self.secondVisit)

        #expect(
            try fixture.store.projects() == [
                ProjectRecord(path: alpha.standardizedFileURL.path, firstSeen: Self.secondVisit, lastSeen: Self.secondVisit)
            ])
    }

    /// Lists `store` under a telemetry capture. A project path is the user's
    /// content, so no log record, span or metric may hold it.
    ///
    /// - Parameters:
    ///   - store: The store to list.
    ///   - projects: The project folders whose paths no telemetry may hold.
    /// - Returns: The path of each listed project, and the count of the
    ///   `warning` records with the skip message.
    private static func listing(
        of store: ProjectStore, forbidding projects: [URL]
    ) async throws -> (paths: [String], warnings: Int) {
        try await TelemetryCapture.run(forbidding: projects.map(\.standardizedFileURL.path)) { context in
            let paths = try store.projects().map(\.path)
            let warnings = context.logRecords.filter {
                $0.level == .warning && "\($0.message)" == Self.skippedFileWarning
            }
            return (paths, warnings.count)
        }
    }
}
