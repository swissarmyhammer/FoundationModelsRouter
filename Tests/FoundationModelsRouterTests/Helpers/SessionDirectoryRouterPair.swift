import Foundation

@testable import FoundationModelsRouter

/// Two routers over one recordings folder, which the directory suites of
/// recorded sessions share (`RouterSessionDirectoryRecordedTests`,
/// `RouterSessionDirectoryTagTests`, ROUTER-3; `RouterSessionDirectoryArchiveTests`,
/// ROUTER-11).
///
/// The recording router records the sessions; the reading router is a new
/// router over the same recordings folder, standing in for a new process,
/// which finds them through the roots the host gives with
/// `useRecordingRoots(_:)`.
struct SessionDirectoryRouterPair {
    /// The cache and recordings folders of the test.
    let directories: TestDirectories

    /// The router that records the sessions.
    let recordingRouter: Router

    /// The resolved profile of ``recordingRouter``.
    let recordingProfile: LanguageModelProfile

    /// The router of the "new process": a second router over the same
    /// recordings folder.
    let readingRouter: Router

    /// The resolved profile of ``readingRouter``.
    let readingProfile: LanguageModelProfile

    /// The directory of ``readingRouter``.
    var directory: RouterSessionDirectory { readingRouter.sessionDirectory }

    /// Makes the two routers over one new recordings folder.
    ///
    /// - Parameters:
    ///   - prefix: The name of the suite, which starts the name of each
    ///     folder of the test.
    ///   - recordingContainer: The container that vends the backend of each
    ///     session of ``recordingRouter``. The default is a basic container.
    /// - Returns: The two routers.
    static func make(
        prefix: String, recordingContainer: any LoadedLLMContainer = BasicLLMContainer()
    ) async throws -> Self {
        let directories = TestDirectories(prefix: prefix)
        let (recordingRouter, recordingProfile) = try await RouterTestFixtures.resolveStandardProfile(
            over: recordingContainer, cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        let (readingRouter, readingProfile) = try await RouterTestFixtures.resolveStandardProfile(
            over: BasicLLMContainer(), cacheDir: directories.cacheDir, recordingsDir: directories.recordingsDir)
        return Self(
            directories: directories, recordingRouter: recordingRouter, recordingProfile: recordingProfile,
            readingRouter: readingRouter, readingProfile: readingProfile)
    }

    /// Vends a root session of ``recordingRouter`` and closes it, so it is
    /// on disk and live nowhere.
    ///
    /// - Parameter configuration: The configuration of the session.
    /// - Returns: The id and the recording directory of the session.
    func recordClosedRoot(
        _ configuration: SessionConfiguration = SessionConfiguration()
    ) async -> (id: ULID, recordingDirectory: URL) {
        let session = recordingProfile.standard.makeSession(configuration: configuration)
        await session.close()
        return (session.id, session.recordingDirectory)
    }

    /// Gives the directory of ``readingRouter`` the recording root of
    /// `recordingDirectory`: the folder that holds it.
    ///
    /// - Parameter recordingDirectory: The recording directory of a root.
    func useRoot(of recordingDirectory: URL) async {
        let root = recordingDirectory.deletingLastPathComponent()
        await directory.useRecordingRoots { [root] }
    }

    /// Removes the folders of the test.
    func remove() {
        directories.remove()
    }
}
