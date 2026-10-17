import Foundation

/// The one cleanup-on-throw step of the fixture makes of the tests (rule T1:
/// a fixture closes also when the body of the test throws).
///
/// The unit tests and the real-model tests in the nested `IntegrationTests/`
/// package each make fixtures with a temporary directory. `swift test` builds
/// one `.xctest` for each test target, and SwiftPM cannot share source between
/// two test targets, so the step stands here one time. ``TextFileLines``
/// stands here for the same reason.
public enum FixtureCleanup {
    /// Runs `body`, and when `body` throws, does `cleanup` and removes
    /// `directory` before it throws the error again.
    ///
    /// A make calls it for each step after it made its temporary directory.
    /// When `body` returns, the directory stays: the end of the fixture
    /// removes it.
    ///
    /// - Parameters:
    ///   - isolation: The isolation of the caller. `body` and `cleanup` run
    ///     there.
    ///   - directory: The temporary directory of the fixture.
    ///   - cleanup: The other cleanup of the fixture when `body` throws, for
    ///     example the close of a session that an earlier step made, or the
    ///     evict of a loaded model. It runs before the removal of
    ///     `directory`. The default does nothing.
    ///   - body: The step that can throw.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws, after the cleanup.
    public static func removingDirectoryOnThrow<Value>(
        isolation: isolated (any Actor)? = #isolation,
        _ directory: URL,
        alsoOnThrow cleanup: () async -> Void = {},
        _ body: () async throws -> Value
    ) async throws -> Value {
        do {
            return try await body()
        } catch {
            await cleanup()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
