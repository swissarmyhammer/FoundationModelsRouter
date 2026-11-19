import Foundation
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// ``ForkBuild``: the one build of the fork of a ``SessionLaunchForkRequest``
/// (D205). A build that is in flight when the fork call closes the build
/// discards the fork that it makes.
@Suite struct ForkBuildTests {
    /// The fixture of this suite: stub backends.
    private typealias Fixture = ForkFixture<ForkTestContainer>

    /// The cut of each fork: the end of the first turn of the source.
    private static let cutPosition = 2

    /// The gate of a builder: the builder waits at it before it builds the
    /// fork, and keeps the fork that it builds.
    private final class BuildGate: Sendable {
        /// Sent when the builder starts.
        let entered = AwaitedEvent()

        /// Sent by the test to let the builder build the fork.
        let release = AwaitedEvent()

        /// The fork that the builder made, or `nil` before it made one.
        private let made = Mutex<RoutedSessionActor?>(nil)

        /// The fork that the builder made, or `nil` before it made one.
        var madeFork: RoutedSessionActor? {
            made.withLock { $0 }
        }

        /// Sends ``entered``, waits for ``release``, and then runs `build`
        /// and keeps its fork.
        ///
        /// - Parameter build: The build of the fork.
        /// - Returns: The fork.
        /// - Throws: The error of the wait or of `build`.
        func pass(
            then build: @Sendable () async throws -> RoutedSessionActor
        ) async throws -> RoutedSessionActor {
            entered.signal()
            try await release.wait()
            let fork = try await build()
            made.withLock { $0 = fork }
            return fork
        }
    }

    /// A build whose builder waits at a gate.
    private struct GatedBuild {
        /// The build under test.
        let build: ForkBuild

        /// The gate of its builder.
        let gate: BuildGate
    }

    /// The result of a build that ends after the close of its build.
    private struct LateBuild {
        /// The result of the build.
        let result: Result<RoutedSessionActor, any Error>

        /// The fork that the builder made.
        let fork: RoutedSessionActor

        /// The folder where the fork records.
        let recordingDirectory: URL
    }

    /// Makes a build of a fork of `source` at ``cutPosition``, whose
    /// builder waits at a gate.
    ///
    /// - Parameter source: The source of the fork.
    /// - Returns: The gated build.
    /// - Throws: The error of the cut.
    private static func makeGatedBuild(of source: RoutedSessionActor) async throws -> GatedBuild {
        let seed = try await source.prepareFork(at: .historyPosition(cutPosition))
        let forkID = ULID.generate()
        let gate = BuildGate()
        let build = ForkBuild(
            forkID: forkID,
            recordingDirectory: source.recordingDirectory.appendingPathComponent(
                forkID.description, isDirectory: true)
        ) { surface in
            try await gate.pass { try await source.makeFork(id: forkID, seed: seed, surface: surface) }
        }
        return GatedBuild(build: build, gate: gate)
    }

    /// Starts a build of a fork of a new source, closes the build while the
    /// builder waits at its gate, and then lets the builder build the fork.
    ///
    /// - Parameter fixture: The fixture of the test.
    /// - Returns: The result of the build, and the source to end.
    /// - Throws: The error of the source or of the cut.
    private static func buildPastTheClose(in fixture: Fixture) async throws -> (LateBuild, any RoutedSession) {
        let source = try await fixture.makeSource(answering: ["first", "second"])
        let gated = try await makeGatedBuild(of: try #require(source as? RoutedSessionActor))
        let building = Task { try await gated.build.make(surface: nil) }
        try await gated.gate.entered.wait()

        _ = gated.build.close()
        gated.gate.release.signal()
        let result = await building.result

        let fork = try #require(gated.gate.madeFork)
        let late = LateBuild(result: result, fork: fork, recordingDirectory: gated.build.recordingDirectory)
        return (late, source)
    }

    @Test func aBuildThatEndsAfterTheCloseThrowsRequestClosed() async throws {
        let fixture = try await Fixture.make()
        let (late, source) = try await Self.buildPastTheClose(in: fixture)

        #expect(throws: SessionLaunchForkError.requestClosed(late.fork.id)) {
            try late.result.get()
        }
        await fixture.end([source, late.fork])
    }

    @Test func aBuildThatEndsAfterTheCloseLeavesNoLiveFork() async throws {
        let fixture = try await Fixture.make()
        let (late, source) = try await Self.buildPastTheClose(in: fixture)

        #expect(await late.fork.isClosed)
        await fixture.end([source, late.fork])
    }

    @Test func aBuildThatEndsAfterTheCloseLeavesNoRecordingFolder() async throws {
        let fixture = try await Fixture.make()
        let (late, source) = try await Self.buildPastTheClose(in: fixture)

        #expect(FileManager.default.fileExists(atPath: late.recordingDirectory.path) == false)
        await fixture.end([source, late.fork])
    }
}

