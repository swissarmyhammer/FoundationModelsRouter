import FoundationModels
import FoundationModelsRouterTestSupport
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// Task ^vg6bmq6: a pass watch of a ``SessionLanguageModelState`` runs only
/// while a pass of its wrapper runs.
///
/// `LanguageModelSession` writes its transcript with no guard between the
/// passes of a tool loop: after a pass, before and after the tool body. A read
/// of `transcript` from another task in that window aborts the process. A pass
/// watch is the one place where the live backend reads the transcript beside a
/// call in flight, so each watch must start inside a pass and end before the
/// pass returns to the SDK.
@Suite("A pass watch runs only inside a pass")
struct SessionLanguageModelPassWatchTests {
    /// The prompt of each call.
    private static let prompt = "look up the record"

    /// How long a watch waits for its cancel. A watch that the end of its pass
    /// does not cancel ends after this span, and the log then records an end
    /// that no cancel caused.
    private static let watchHold: Duration = .seconds(60)

    /// Makes a session over a new wrapper of a model that asks for one tool
    /// in its first pass and answers in its second pass.
    ///
    /// - Parameter tool: The one tool of the session.
    /// - Returns: The session and the per-session state of its wrapper.
    private static func makeSession(tool: WatchCountingTool) -> (LanguageModelSession, SessionLanguageModelState) {
        let model = SessionLanguageModel(
            wrapping: ToolResultCompactionModel(toolCallUsage: MeteredGenerationCall(tokensIn: 1, tokensOut: 1)))
        return (LanguageModelSession(model: model, tools: [tool]), model.state)
    }

    /// Makes a watch that records its start, waits for its cancel, and
    /// records its end.
    ///
    /// - Parameter log: The log the watch records into.
    /// - Returns: The watch.
    private static func recordingWatch(into log: PassWatchLog) -> SessionLanguageModelState.PassWatch {
        {
            log.recordStart()
            try? await Task.sleep(for: watchHold)
            log.recordEnd(cancelled: Task.isCancelled)
        }
    }

    /// The production change that makes this test fail: a pass that returns
    /// to the SDK while its watch still runs, or a watch that runs outside a
    /// pass. The tool body then sees a watch that has not ended.
    @Test("each pass of a tool loop runs the watch, and the watch has ended before the tool runs")
    func watchRunsInsideEachPassOnly() async throws {
        let log = PassWatchLog()
        let tool = WatchCountingTool(log: log)
        let (session, state) = Self.makeSession(tool: tool)
        _ = state.addPassWatch(Self.recordingWatch(into: log))

        _ = try await session.respond(to: Self.prompt)

        let atTool = try #require(tool.countsAtCall)
        #expect(atTool == PassWatchLog.Counts(starts: 1, ends: 1, uncancelledEnds: 0))
        #expect(log.counts == PassWatchLog.Counts(starts: 2, ends: 2, uncancelledEnds: 0))
    }

    /// The production change that makes this test fail: a removed watch that
    /// still runs in the passes of its wrapper.
    @Test("a removed watch does not run in a later pass")
    func removedWatchDoesNotRun() async throws {
        let log = PassWatchLog()
        let (session, state) = Self.makeSession(tool: WatchCountingTool(log: log))
        let watch = state.addPassWatch(Self.recordingWatch(into: log))
        state.removePassWatch(watch)

        _ = try await session.respond(to: Self.prompt)

        #expect(log.counts == PassWatchLog.Counts(starts: 0, ends: 0, uncancelledEnds: 0))
    }
}

/// What the watches of one test recorded: each start and each end.
///
/// A lock guards the counts, because each watch records from a task of its
/// own while the tool and the test read them.
final class PassWatchLog: Sendable {
    /// The counts of the starts and the ends of the watches.
    struct Counts: Sendable, Equatable {
        /// How many watches started.
        var starts = 0

        /// How many watches ended.
        var ends = 0

        /// How many watches ended with no cancel.
        var uncancelledEnds = 0
    }

    /// The counts so far.
    private let state = Mutex(Counts())

    /// The counts so far.
    var counts: Counts {
        state.withLock { $0 }
    }

    /// Records that a watch started.
    func recordStart() {
        state.withLock { $0.starts += 1 }
    }

    /// Records that a watch ended.
    ///
    /// - Parameter cancelled: Whether a cancel ended the watch.
    func recordEnd(cancelled: Bool) {
        state.withLock { counts in
            counts.ends += 1
            if !cancelled {
                counts.uncancelledEnds += 1
            }
        }
    }
}

/// A tool whose body keeps the watch counts as they are when the SDK runs the
/// tool, between the two passes of the call.
final class WatchCountingTool: Tool, Sendable {
    /// The name the model calls the tool by: the one tool that
    /// ``ToolResultCompactionModel`` asks for.
    let name = LargeResultTool.toolName

    /// The description the model reads.
    let description = "test-only tool that keeps the pass watch counts at its call"

    /// The log of the watches of the session.
    private let log: PassWatchLog

    /// The counts at the call, or `nil` before the call.
    private let countsAtCallState = Mutex<PassWatchLog.Counts?>(nil)

    /// Makes the tool.
    ///
    /// - Parameter log: The log of the watches of the session.
    init(log: PassWatchLog) {
        self.log = log
    }

    /// The watch counts as they were when the tool ran, or `nil` when the
    /// tool did not run.
    var countsAtCall: PassWatchLog.Counts? {
        countsAtCallState.withLock { $0 }
    }

    /// Keeps the watch counts of this moment.
    ///
    /// - Parameter arguments: The arguments of the call. Unread.
    /// - Returns: A short result.
    func call(arguments: AmbientToolArguments) async throws -> String {
        let counts = log.counts
        countsAtCallState.withLock { $0 = counts }
        return "RESULT"
    }
}
