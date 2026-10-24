import FoundationModels
import Testing

@testable import FoundationModelsRouter

/// A pass over a ``SessionLanguageModel`` keeps the task-locals of the caller
/// of the SDK call (tasks ^a0ze9af, ^1psqdm9 and ^qhgfajc).
///
/// ``SubmitterMarkModel`` answers with the value of a task-local that the
/// test binds around the SDK call. The SDK gives task-locals to the executor
/// (the control test). The wrapper calls the model through
/// `PooledGeneration.run(ref:channel:_:)`, whose task keeps the task-locals
/// of its caller. Thus the pass sees the mark of the caller, and a tool body
/// reads the bindings of its model call.
@Suite("A pass over the wrapper keeps the task-locals of its caller (tasks ^a0ze9af, ^1psqdm9, ^qhgfajc)")
struct SessionLanguageModelTaskLocalTests {
    /// The task-local that the test binds around the SDK call.
    enum SubmitterMark {
        /// The mark of the task that calls the SDK, or `nil` when no caller
        /// bound one.
        @TaskLocal static var value: String?
    }

    /// A scripted `LanguageModel` whose one pass answers with the
    /// ``SubmitterMark`` that the task of the pass sees.
    struct SubmitterMarkModel: LanguageModel {
        /// The text an answer opens with.
        static let answerPrefix = "seen: "

        /// The mark an answer names when the pass sees no mark.
        static let noMark = "none"

        /// The answer of a pass that sees `mark`.
        ///
        /// - Parameter mark: The mark the pass sees, or `nil`.
        /// - Returns: The answer text.
        static func answer(seeing mark: String?) -> String {
            answerPrefix + (mark ?? noMark)
        }

        /// The model answers text only.
        var capabilities: LanguageModelCapabilities { LanguageModelCapabilities([]) }

        /// The empty executor cache key.
        var executorConfiguration: Executor.Configuration { Executor.Configuration() }

        /// The executor that answers with the mark its task sees.
        struct Executor: LanguageModelExecutor {
            /// The empty cache key: the executor holds no data.
            struct Configuration: Sendable, Hashable {}

            /// The model type this executor serves.
            typealias Model = SubmitterMarkModel

            /// The token count the one emitted fragment reports.
            private static let emittedTokenCount = 1

            /// Makes the executor. The configuration carries no data.
            ///
            /// - Parameter configuration: The empty configuration.
            /// - Throws: Never. `throws` comes from the protocol requirement.
            init(configuration: Configuration) throws {}

            /// Answers with the mark that the task of this pass sees.
            ///
            /// - Parameters:
            ///   - request: The generation request. Unread.
            ///   - model: The model. Unread.
            ///   - channel: The channel the pass emits into.
            /// - Throws: Never. `throws` comes from the protocol requirement.
            func respond(
                to request: LanguageModelExecutorGenerationRequest,
                model: SubmitterMarkModel,
                streamingInto channel: LanguageModelExecutorGenerationChannel
            ) async throws {
                let text = SubmitterMarkModel.answer(seeing: SubmitterMark.value)
                await channel.send(.response(action: .appendText(text, tokenCount: Self.emittedTokenCount)))
            }
        }
    }

    /// The mark the test binds around each SDK call.
    private static let submitterMark = "submitter"

    /// Calls the SDK over `model` with ``SubmitterMark`` bound.
    ///
    /// - Parameter model: The model of the SDK session.
    /// - Returns: The content of the SDK response.
    /// - Throws: What the SDK call throws.
    private static func respondWithMark(over model: some LanguageModel) async throws -> String {
        try await SubmitterMark.$value.withValue(submitterMark) {
            let session = LanguageModelSession(model: model, tools: [])
            return try await session.respond(to: "which mark").content
        }
    }

    @Test("over the raw model, the SDK gives the task-local of the caller to the pass (the control)")
    func theSDKGivesTheCallerTaskLocalToThePass() async throws {
        let content = try await Self.respondWithMark(over: SubmitterMarkModel())

        #expect(content == SubmitterMarkModel.answer(seeing: Self.submitterMark))
    }

    @Test("over the wrapper, the pass keeps the task-local of the caller, and returns the output of its pass")
    func aPassOverTheWrapperKeepsTheTaskLocalOfTheCaller() async throws {
        let model = SessionLanguageModel(wrapping: SubmitterMarkModel(), ref: ModelRef(repo: "test/submitter-mark"))

        let content = try await Self.respondWithMark(over: model)

        #expect(content == SubmitterMarkModel.answer(seeing: Self.submitterMark))
    }
}
