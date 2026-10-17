import Foundation
import FoundationModelsRouterTestSupport
import Testing

/// Holds ``FixtureCleanup`` to its contract: when the step throws, the other
/// cleanup runs, the directory goes, and the caller gets the error; when the
/// step returns, the caller gets its value and the directory stays.
@Suite("FixtureCleanup")
struct FixtureCleanupTests {
    /// The error that the step of a test throws.
    private struct StepFailed: Error {}

    /// What the step of a test returns.
    private static let stepValue = "the value of the step"

    /// Makes a fresh directory under the temporary directory.
    ///
    /// - Returns: The directory.
    /// - Throws: What the make of the directory throws.
    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FixtureCleanupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The production change that makes this test fail: a cleanup that does
    /// not run the other cleanup, keeps the directory, or does not throw the
    /// error again.
    @Test("a step that throws runs the other cleanup, removes the directory and throws the error again")
    @MainActor
    func aStepThatThrowsCleansUp() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var otherCleanupRan = false

        await #expect(throws: StepFailed.self) {
            try await FixtureCleanup.removingDirectoryOnThrow(directory, alsoOnThrow: { otherCleanupRan = true }) {
                throw StepFailed()
            }
        }
        #expect(otherCleanupRan)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    /// The production change that makes this test fail: a cleanup that also
    /// runs when the step returns, or that loses the value of the step.
    @Test("a step that returns gives its value and keeps the directory")
    @MainActor
    func aStepThatReturnsKeepsTheDirectory() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var otherCleanupRan = false

        let value = try await FixtureCleanup.removingDirectoryOnThrow(
            directory, alsoOnThrow: { otherCleanupRan = true }
        ) {
            Self.stepValue
        }
        #expect(value == Self.stepValue)
        #expect(!otherCleanupRan)
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }
}
