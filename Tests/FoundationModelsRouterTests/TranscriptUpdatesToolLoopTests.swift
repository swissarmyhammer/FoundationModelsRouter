import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// Task ^vg6bmq6: the transcript updates of the live backend read the
/// transcript of the SDK session only while a pass of the session runs.
///
/// `LanguageModelSession` writes its transcript with no guard between the
/// passes of a tool loop. A read of `transcript` from another task in that
/// window races the write, and the runtime aborts the process with
/// "_ContiguousArrayStorage deallocated with non-zero retain count 2". The
/// repetition watch reads the updates on a task of its own, so each model call
/// that asks for a tool was exposed.
@Suite("The transcript updates of the live backend beside a tool loop")
struct TranscriptUpdatesToolLoopTests {
    /// How many backends run their tool loops at the same time.
    private static let concurrentBackends = 64

    /// How many tool loops each backend runs, one after the other.
    private static let callsPerBackend = 256

    /// How many readers take the transcript updates of each call. More than
    /// one reader makes more reads, so a read in the unguarded window of the
    /// SDK comes in fewer calls.
    private static let readersPerCall = 4

    /// The prompt of each call.
    private static let prompt = "look up the record"

    /// Runs one tool loop on `backend` while ``readersPerCall`` readers take
    /// each transcript update, as the repetition watch does.
    ///
    /// - Parameter backend: The live backend to drive.
    /// - Throws: What the stream of the call throws.
    private static func toolLoopBesideUpdates(on backend: any LanguageModelSessionBackend) async throws {
        let readers = (0..<readersPerCall).map { _ in
            let updates = backend.transcriptUpdates()
            return Task {
                for await _ in updates {}
            }
        }
        for try await _ in backend.streamResponseFragments(to: prompt, maxTokens: nil) {}
        for reader in readers {
            reader.cancel()
            await reader.value
        }
    }

    /// Makes a live backend over a model that asks for one tool, then answers.
    ///
    /// - Returns: The backend.
    private static func makeToolBackend() -> any LanguageModelSessionBackend {
        let container = LiveBackendContainer(
            model: ToolResultCompactionModel(toolCallUsage: MeteredGenerationCall(tokensIn: 1, tokensOut: 1)))
        return container.makeSession(instructions: nil, tools: [LargeResultTool(result: "RESULT")])
    }

    /// The production change that makes this test fail: a
    /// `transcriptUpdates()` that reads `LanguageModelSession.transcript`
    /// between two passes of a tool loop. The process then aborts: 5 of 8
    /// runs of this test aborted on the tree before the fix. A read loop that
    /// does not end at the cancel of its pass makes the calls hang, and the
    /// time limit turns that hang into a failure.
    @Test("tool loops beside readers of the transcript updates all complete", .timeLimit(.minutes(1)))
    func toolLoopsBesideUpdatesComplete() async throws {
        let completedCalls = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<Self.concurrentBackends {
                group.addTask {
                    for _ in 0..<Self.callsPerBackend {
                        try await Self.toolLoopBesideUpdates(on: Self.makeToolBackend())
                    }
                    return Self.callsPerBackend
                }
            }
            return try await group.reduce(0, +)
        }

        #expect(completedCalls == Self.concurrentBackends * Self.callsPerBackend)
    }
}
