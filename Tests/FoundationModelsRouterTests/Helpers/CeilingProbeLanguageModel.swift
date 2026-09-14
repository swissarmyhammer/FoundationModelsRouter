import Foundation
import FoundationModels
import Synchronization

@testable import FoundationModelsRouter

/// The token ceilings a ``CeilingProbeLanguageModel`` was asked to generate
/// under, one for each generation call, in call order.
///
/// A class behind a lock, because the SDK generates on a task of its own while
/// the test reads the log on the task that drove the turn. It is `Hashable` by
/// identity, so it can be part of the executor cache key.
final class CeilingProbeLog: Sendable, Hashable {
    /// The ceilings seen so far. `nil` is a call that named no ceiling.
    private let ceilings: Mutex<[Int?]> = Mutex([])

    /// The `maximumResponseTokens` of each generation call, in call order.
    var requestedCeilings: [Int?] { ceilings.withLock { $0 } }

    /// Records the ceiling of one generation call.
    ///
    /// - Parameter ceiling: The `maximumResponseTokens` the call carried.
    /// - Returns: The zero-based position of this call in the log.
    func record(ceiling: Int?) -> Int {
        ceilings.withLock { ceilings in
            ceilings.append(ceiling)
            return ceilings.count - 1
        }
    }

    /// Two logs are equal only when they are the same log.
    static func == (lhs: CeilingProbeLog, rhs: CeilingProbeLog) -> Bool {
        lhs === rhs
    }

    /// Hashes the identity of the log.
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

/// How a ``CeilingProbeLanguageModel`` ends each generation call.
enum CeilingProbeEnding: Sendable, Hashable {
    /// The model closes its thought and gives a short answer.
    case finished

    /// The model runs out of budget inside its thought. The executor then
    /// sends the `incompleteOutput` metadata the MLX executor sends.
    case truncatedInsideReasoning

    /// The first generation call ends as ``truncatedInsideReasoning``, and
    /// each later call ends as ``finished``.
    case truncatedOnFirstCallOnly

    /// Whether the call at `callIndex` runs out of budget inside its thought.
    ///
    /// - Parameter callIndex: The zero-based position of the call in the log.
    /// - Returns: `true` when the call sends the `incompleteOutput` metadata.
    func truncates(callIndex: Int) -> Bool {
        switch self {
        case .finished:
            return false
        case .truncatedInsideReasoning:
            return true
        case .truncatedOnFirstCallOnly:
            return callIndex == 0
        }
    }
}

/// A deterministic `LanguageModel` that records the ceiling of each call and
/// ends the call as ``CeilingProbeEnding`` says.
///
/// The truncated ending sends the same channel actions as the MLX executor of
/// `MLXFoundationModels` when generation stops inside a reasoning block:
/// reasoning text, then `["incompleteOutput": true]` as metadata on the
/// response entry, with no response text.
struct CeilingProbeLanguageModel: LanguageModel {
    /// How each generation call ends.
    let ending: CeilingProbeEnding

    /// The log each generation call writes its ceiling into.
    let log: CeilingProbeLog

    /// Declares reasoning, because the executor sends a reasoning entry.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning]) }

    /// Builds the executor cache key from the ending and the log.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(ending: ending, log: log)
    }

    /// The executor that records the ceiling and plays out the ending.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by.
        struct Configuration: Sendable, Hashable {
            /// How each generation call ends.
            let ending: CeilingProbeEnding

            /// The log to write each ceiling into.
            let log: CeilingProbeLog
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = CeilingProbeLanguageModel

        /// The token count every emitted fragment reports.
        private static let emittedTokenCount = 1

        /// The reasoning text each call sends before it ends.
        private static let reasoningText = "Let me think about the whole problem before I"

        /// The answer text a finished call sends.
        static let answerText = "The answer is ready."

        /// The response entry id the call at `callIndex` sends its answer or
        /// its metadata under. Each call gets its own id, as each MLX call does.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The entry id.
        private static func responseEntryID(callIndex: Int) -> String {
            "ceiling-probe-response-\(callIndex)"
        }

        /// The reasoning entry id the call at `callIndex` sends its thought under.
        ///
        /// - Parameter callIndex: The zero-based position of the call.
        /// - Returns: The entry id.
        private static func reasoningEntryID(callIndex: Int) -> String {
            "ceiling-probe-reasoning-\(callIndex)"
        }

        /// The metadata key the MLX executor sends when the budget ends inside
        /// a thought. Spelled here as the upstream literal, so the test proves
        /// the wire contract and not a shared constant.
        private static let incompleteOutputKey = "incompleteOutput"

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The ending and the log.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Records the ceiling, sends the thought, and ends the call.
        ///
        /// - Parameters:
        ///   - request: The generation request, carrying the ceiling.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: CeilingProbeLanguageModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = configuration.log.record(ceiling: request.generationOptions.maximumResponseTokens)
            await channel.send(
                .reasoning(
                    entryID: Self.reasoningEntryID(callIndex: callIndex),
                    action: .appendText(Self.reasoningText, tokenCount: Self.emittedTokenCount)))
            let responseEntryID = Self.responseEntryID(callIndex: callIndex)
            guard configuration.ending.truncates(callIndex: callIndex) else {
                await channel.send(
                    .response(
                        entryID: responseEntryID,
                        action: .appendText(Self.answerText, tokenCount: Self.emittedTokenCount)))
                return
            }
            await channel.send(
                .response(
                    entryID: responseEntryID,
                    action: .updateMetadata([Self.incompleteOutputKey: true])))
        }
    }
}

/// A ``LoadedLLMContainer`` that vends the production
/// ``MLXFoundationModelsSessionBackend`` over a ``CeilingProbeLanguageModel``,
/// so a routed session drives the real backend with no GPU.
struct CeilingProbeContainer: LoadedLLMContainer {
    /// The probe model every backend of this container runs over.
    let model: CeilingProbeLanguageModel

    /// Vends a backend over a fresh session carrying `instructions`.
    ///
    /// - Parameter instructions: The session's system instructions, or `nil`.
    /// - Returns: A live backend over ``model``.
    func makeSession(instructions: String?) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            session: LanguageModelSession(model: model, instructions: instructions),
            model: model,
            instructions: instructions)
    }

    /// Vends a backend over a fresh session seeded from `transcript`.
    ///
    /// - Parameter transcript: The transcript to seed the session from.
    /// - Returns: A live backend over ``model``.
    func makeSession(transcript: Transcript) -> any LanguageModelSessionBackend {
        MLXFoundationModelsSessionBackend(
            session: LanguageModelSession(model: model, transcript: transcript),
            model: model,
            instructions: TranscriptDiffer.leadingInstructionsText(of: transcript))
    }
}

/// A routed session over a ``CeilingProbeContainer``, with the log its model
/// writes into and the directory the router cached into.
struct CeilingProbeSessionFixture {
    /// The vended session a test drives its turn on.
    let session: RoutedSession

    /// The log of the ceiling of each generation call.
    let log: CeilingProbeLog

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router, resolves a profile at `context`, and vends a session
    /// over a probe model that ends each call as `ending` says.
    ///
    /// - Parameters:
    ///   - ending: How each generation call ends.
    ///   - context: The working context the profile resolves at.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The session, its log, and the temp directory.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        ending: CeilingProbeEnding,
        context: Int = ProfileDefinition.defaultContext,
        tempDirPrefix: String
    ) async throws -> CeilingProbeSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let log = CeilingProbeLog()
        let container = CeilingProbeContainer(model: CeilingProbeLanguageModel(ending: ending, log: log))
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            loader: StubModelLoader(container: container, dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(
            profile: RouterTestFixtures.profile(context: context), reporting: ResolutionProgress())
        return CeilingProbeSessionFixture(session: profile.standard.makeSession(), log: log, directory: directory)
    }
}
