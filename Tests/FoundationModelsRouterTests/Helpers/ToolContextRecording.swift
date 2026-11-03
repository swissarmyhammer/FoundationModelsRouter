import Foundation
import FoundationModels
import FoundationModelsExtras
import FoundationModelsRouterTestSupport
import Synchronization

@testable import FoundationModelsRouter

/// The `ToolContext` of the last call of each session, by session id.
///
/// A tool saves its context here while a session runs. A test reads the
/// context after the run, for the ids and for the reader of transcripts that
/// the context holds.
final class ContextStore: Sendable {
    private let contexts = Mutex<[ULID: ToolContext]>([:])

    /// Saves the context of one call.
    ///
    /// - Parameter context: The context of the call.
    func save(_ context: ToolContext) {
        contexts.withLock { $0[context.sessionID] = context }
    }

    /// The context of the last call of `session`, or `nil` when there was none.
    ///
    /// - Parameter session: The session to read.
    /// - Returns: The saved context, or `nil`.
    func context(of session: ULID) -> ToolContext? {
        contexts.withLock { $0[session] }
    }
}

/// A tool that saves the `ToolContext` of each call in a store.
struct ContextRecordingTool: Tool {
    let name: String
    let description = "test-only tool that saves the context of its call"
    let store: ContextStore

    func call(arguments: BackgroundFixtureArguments) async throws -> String {
        if let context = ToolContext.current { store.save(context) }
        return "recorded"
    }
}

/// A container whose backend calls each tool, also for a restored session.
final class ToolDrivingLLMContainer: LoadedLLMContainer {
    let tokenCounter: any TokenCounter = CharacterTokenCounter()

    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        makeSession(instructions: instructions, tools: [])
    }

    func makeSession(instructions: String?, tools: [any Tool]) -> any LanguageModelSessionBackend {
        BackgroundingBackend(tools: tools)
    }

    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        makeSession(transcript: transcript, tools: [])
    }

    func makeSession(transcript: Transcript, tools: [any Tool]) -> any LanguageModelSessionBackend {
        BackgroundingBackend(tools: tools)
    }
}
