import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport

@testable import FoundationModelsRouter

/// A deterministic `LanguageModel` that plays one script for each call, in
/// call order (task ^0dcsd3t).
///
/// Call `i` writes the reasoning of `scripts[i]` and waits for its hold, as a
/// ``RepeatingReasoningModel`` call does. A call after the last script
/// answers with ``RepeatingReasoningModel/Executor/answerText`` at once. So a
/// test can make the first call repeat itself and the next calls reason past
/// the limit. Each call records its transcript and its reasoning level in
/// ``log``.
struct StagedReasoningModel: LanguageModel, ReasoningSwitchable {
    /// The log that records the transcript and the reasoning level of each call.
    let log: RenderProbeLog

    /// The script of each call, in call order.
    let scripts: [RepeatingReasoningScript]

    /// Declares reasoning, because each call writes a reasoning entry, and
    /// tool calling, as the model of a session with tools must.
    var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([.reasoning, .toolCalling]) }

    /// Builds the executor cache key from the log and the scripts.
    var executorConfiguration: Executor.Configuration {
        Executor.Configuration(log: log, scripts: scripts)
    }

    /// Always `true`: the model turns its reasoning off for one call, as a
    /// model with a chat template flag does.
    ///
    /// - Returns: `true`.
    func canTurnReasoningOff() async throws -> Bool {
        true
    }

    /// The executor that plays out each call.
    struct Executor: LanguageModelExecutor {
        /// Cache key the SDK creates and reuses this executor by. The log is
        /// compared and hashed by identity, so two tests never share an
        /// executor.
        struct Configuration: Sendable, Hashable {
            /// The log that records each call.
            let log: RenderProbeLog

            /// The script of each call, in call order.
            let scripts: [RepeatingReasoningScript]

            static func == (lhs: Self, rhs: Self) -> Bool {
                lhs.log === rhs.log && lhs.scripts == rhs.scripts
            }

            func hash(into hasher: inout Hasher) {
                hasher.combine(ObjectIdentifier(log))
                hasher.combine(scripts)
            }
        }

        /// The `LanguageModel` this executor conforms for.
        typealias Model = StagedReasoningModel

        /// The cache-key configuration the SDK constructed this executor with.
        private let configuration: Configuration

        /// Stores the cache-key configuration.
        ///
        /// - Parameter configuration: The log and the scripts.
        /// - Throws: Never. `throws` comes from the `LanguageModelExecutor`
        ///   requirement.
        init(configuration: Configuration) throws {
            self.configuration = configuration
        }

        /// Plays the script of this call, then answers.
        ///
        /// - Parameters:
        ///   - request: The generation request of the call.
        ///   - model: The model this executor runs for. Unread.
        ///   - channel: The generation channel this call emits into.
        /// - Throws: `CancellationError` when the session stops the call.
        func respond(
            to request: LanguageModelExecutorGenerationRequest,
            model: StagedReasoningModel,
            streamingInto channel: LanguageModelExecutorGenerationChannel
        ) async throws {
            let callIndex = configuration.log.renders.count
            configuration.log.record(render: request.transcript)
            configuration.log.record(reasoningLevel: request.contextOptions.reasoningLevel)
            if configuration.scripts.indices.contains(callIndex) {
                try await RepeatingReasoningModel.Executor.writeReasoning(
                    configuration.scripts[callIndex], into: channel)
            }
            await channel.send(
                .response(
                    entryID: "staged-answer-\(UUID().uuidString)",
                    action: .appendText(
                        RepeatingReasoningModel.Executor.answerText,
                        tokenCount: RepeatingReasoningModel.Executor.emittedTokenCount)))
        }
    }
}

/// A routed session over a ``LiveBackendContainer`` that runs a
/// ``StagedReasoningModel``, with the log of the model and the recorder that
/// holds the run journal of the session.
struct StagedReasoningSessionFixture {
    /// The vended session a test drives its answers on.
    let session: RoutedSession

    /// The log that the model writes.
    let log: RenderProbeLog

    /// The recorder the router persists every transcript event into.
    let recorder: InMemoryRecorder

    /// The temp directory the router cached into, which the caller must remove.
    let directory: URL

    /// Builds a router and vends a session over a ``StagedReasoningModel``
    /// with `detection`.
    ///
    /// - Parameters:
    ///   - scripts: The script of each call, in call order.
    ///   - detection: The repetition detection the session is made with.
    ///   - tempDirPrefix: The calling suite's name, so a leaked temp directory
    ///     is attributable.
    /// - Returns: The fixture.
    /// - Throws: Whatever profile resolution throws.
    static func make(
        scripts: [RepeatingReasoningScript], detection: RepetitionDetection, tempDirPrefix: String
    ) async throws -> StagedReasoningSessionFixture {
        let directory = RouterTestFixtures.makeTempDir(prefix: tempDirPrefix)
        let recorder = InMemoryRecorder()
        let log = RenderProbeLog()
        let router = RouterTestFixtures.makeRouter(
            cacheDir: directory,
            recorder: recorder,
            loader: StubModelLoader(
                container: LiveBackendContainer(model: StagedReasoningModel(log: log, scripts: scripts)),
                dimension: RouterTestFixtures.stubDimension))
        let profile = try await router.resolve(profile: RouterTestFixtures.profile(), reporting: ResolutionProgress())
        let session = profile.standard.makeSession(configuration: SessionConfiguration(repetitionDetection: detection))
        return StagedReasoningSessionFixture(session: session, log: log, recorder: recorder, directory: directory)
    }
}

/// A ``CeilingProbeLanguageModel`` turns its reasoning off for one call, as a
/// model with a chat template flag does (task ^0dcsd3t), so the log records
/// the level of a recovery call.
extension CeilingProbeLanguageModel: ReasoningSwitchable {
    /// Always `true`.
    ///
    /// - Returns: `true`.
    func canTurnReasoningOff() async throws -> Bool {
        true
    }
}
