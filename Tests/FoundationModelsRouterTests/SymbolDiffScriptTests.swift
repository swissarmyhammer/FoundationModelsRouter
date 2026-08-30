import Foundation
import Testing

/// Runs the hermetic unit tests of `scripts/symboldiff.py`, the public-surface
/// reader and revision differ (task ^1y4g20q).
///
/// The script's own tests are Python, and the shared CI workflow this
/// repository calls runs `swift test` and nothing else. Without this suite the
/// Python tests would be a test target no CI task measures, which gives no
/// protection at all. Running them from here puts them inside the one unit
/// target CI already runs.
///
/// Nothing here builds a Swift package or reaches a network: every test in
/// `scripts/test_symboldiff.py` writes its own symbol-graph JSON into a
/// temporary directory, so the whole run finishes in well under a second.
@Suite("symboldiff script")
struct SymbolDiffScriptTests {
    @Test("the symboldiff unit tests pass")
    func symbolDiffUnitTestsPass() throws {
        let finished = try Self.runScriptTests()
        #expect(
            finished.status == 0,
            """
            python3 -m unittest over scripts/ exited \(finished.status). The symboldiff \
            script is the check a demotion card runs before it narrows an access level, \
            so a failure here means that check is unmeasured:
            \(finished.output)
            """
        )
    }

    @Test("the symboldiff unit tests are not silently empty")
    func symbolDiffUnitTestsMeasureSomething() throws {
        let finished = try Self.runScriptTests()
        #expect(
            !finished.output.contains("Ran 0 tests"),
            """
            python3 -m unittest discovered no test under scripts/. A run that measured \
            nothing exits 0 and reads exactly like a passing suite; found:
            \(finished.output)
            """
        )
    }

    /// The exit status of one `unittest` run, and everything it wrote.
    private struct Finished {
        /// The process exit status. `unittest` writes 0 only when every test passed.
        let status: Int32
        /// Standard output and standard error together, as the runner interleaved them.
        let output: String
    }

    /// Runs `python3 -m unittest` over the `scripts/` directory of this
    /// repository and collects what it wrote.
    ///
    /// The pipe is drained to end of file before the wait, so a run that writes
    /// more than the pipe buffer holds cannot deadlock.
    ///
    /// - Returns: the exit status and the combined output of the run.
    /// - Throws: an error when the process cannot be started.
    private static func runScriptTests() throws -> Finished {
        let unittest = Process()
        unittest.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        unittest.arguments = [
            "python3", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py",
        ]
        unittest.currentDirectoryURL = repositoryRoot
        let written = Pipe()
        unittest.standardOutput = written
        unittest.standardError = written

        try unittest.run()
        let data = written.fileHandleForReading.readDataToEndOfFile()
        unittest.waitUntilExit()
        return Finished(
            status: unittest.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    /// The repository root, resolved relative to this source file's own path
    /// (`#filePath` is `Tests/FoundationModelsRouterTests/SymbolDiffScriptTests.swift`,
    /// two directories below the root). Keep this file directly inside
    /// `Tests/FoundationModelsRouterTests/`, or adjust the step count to match
    /// the new location.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/FoundationModelsRouterTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repository root
    }
}
