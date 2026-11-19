import Foundation
import FoundationModels
import FoundationModelsExtras
import Synchronization
import Testing

@testable import FoundationModelsRouter

/// The arguments of ``CheckpointForkingTool``: one short word that the tool
/// does not read.
@Generable
struct CheckpointArguments {
    /// Any short word. The tool does not read it.
    @Guide(description: "A short name for the checkpoint.")
    let name: String
}

/// A tool that forks the session of its call at the call
/// (``SessionForkCut/callingToolCall``), as the `fork session` tool of
/// Multitool does (D205). It forks one time: a later call, also a call of
/// the fork, which has the same tool, forks nothing.
final class CheckpointForkingTool: FoundationModels.Tool, Sendable {
    /// The error of a call that runs outside a tool call of a session.
    struct NoToolContext: Error {}

    /// The model-facing name.
    static let toolName = "save_checkpoint"

    /// The output of each call.
    static let output = "Checkpoint saved."

    /// The model-facing name.
    let name = CheckpointForkingTool.toolName

    /// The model-facing description.
    let description = "Saves a checkpoint of this conversation."

    /// The directory that the call forks through.
    private let directory: RouterSessionDirectory

    /// The id of the fork, or `nil` before the first call.
    private let forkID = Mutex<ULID?>(nil)

    /// Makes a tool that forks through `directory`.
    ///
    /// - Parameter directory: The directory that the first call forks
    ///   through.
    init(directory: RouterSessionDirectory) {
        self.directory = directory
    }

    /// The id of the fork that the first call made, or `nil` before it.
    var madeForkID: ULID? {
        forkID.withLock { $0 }
    }

    /// Forks the session of the call at the call, on the first call only.
    ///
    /// - Parameter arguments: The arguments of the call. The tool does not
    ///   read them.
    /// - Returns: ``output``.
    /// - Throws: ``NoToolContext`` outside a tool call of a session, or the
    ///   error of the fork.
    func call(arguments: CheckpointArguments) async throws -> String {
        guard let source = ToolContext.current?.sessionID else { throw NoToolContext() }
        guard madeForkID == nil else { return Self.output }
        let summary = try await directory.fork(
            SessionForkRequest(sourceID: source, cut: .callingToolCall, forker: .session(source)))
        forkID.withLock { $0 = summary.id }
        return Self.output
    }
}

/// A host launcher that builds each fork through the request with a tool
/// surface of its own: no tool, as the sources of the fork suite have none.
/// It starts and restores no session.
struct ForkBuildingLauncher: SessionLauncher {
    /// The error of a start or a restore, which the fork suite never asks
    /// for.
    struct Unsupported: Error {}

    /// Refuses the start: the fork suite starts no root session through the
    /// launcher.
    ///
    /// - Parameter request: The start request.
    /// - Returns: Never.
    /// - Throws: ``Unsupported``.
    func launchRootSession(for request: SessionStartRequest) async throws -> any RoutedSession {
        throw Unsupported()
    }

    /// Refuses the restore: each source of the fork suite is live.
    ///
    /// - Parameter id: The id of the session to restore.
    /// - Returns: Never.
    /// - Throws: ``Unsupported``.
    func restoreSession(id: ULID) async throws -> any RoutedSession {
        throw Unsupported()
    }

    /// Builds the fork of `request` with no tool.
    ///
    /// - Parameter request: The fork request of the directory.
    /// - Returns: The fork, not registered.
    /// - Throws: The error of the build.
    func forkSession(_ request: SessionLaunchForkRequest) async throws -> any RoutedSession {
        try await request.makeFork(tools: [])
    }
}

/// One answer of a session: the reply and the usage of each generation call
/// of the answer, in order.
struct MeasuredAnswer {
    /// The final reply.
    let reply: String

    /// The usage of each generation call, in order.
    let calls: [GenerationCallUsage]

    /// Answers `prompt` on `session`, and reads the reply and the usage of
    /// each call from the events of the answer.
    ///
    /// - Parameters:
    ///   - prompt: The prompt.
    ///   - session: The session that answers.
    ///   - maxTokens: The reply ceiling of the answer.
    /// - Returns: The answer.
    /// - Throws: What the answer throws, or the `#require` failure of an
    ///   answer with no final reply.
    static func answer(to prompt: String, on session: any RoutedSession, maxTokens: Int) async throws -> Self {
        let events = try await session.streamEvents(to: prompt, maxTokens: maxTokens)
            .reduce(into: [SessionEvent]()) { $0.append($1) }
        let replies = events.compactMap { event -> String? in
            guard case .answered(let answer) = event else { return nil }
            return answer.reply
        }
        let calls = events.compactMap { event -> GenerationCallUsage? in
            guard case .generationCall(let usage) = event else { return nil }
            return usage
        }
        return Self(reply: try #require(replies.last), calls: calls)
    }
}

extension GenerationCallUsage {
    /// The tokens of the history that this call left in the prompt cache:
    /// the tokens of its prompt and of its reply.
    var historyTokens: Int { tokensIn + tokensOut }
}

extension PromptCacheUsage {
    /// The bytes of the prompt cache in memory, spilling and on disk.
    var totalBytes: Int { memoryBytes + spillingBytes + diskBytes }
}
