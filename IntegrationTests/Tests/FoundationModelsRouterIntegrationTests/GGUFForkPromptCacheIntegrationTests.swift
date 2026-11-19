import Foundation
import FoundationModels
import FoundationModelsRouterRealModelSupport
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter

/// The standard model of this suite: Qwen2.5 1.5B Instruct in the Qwen
/// Q4_K_M conversion, 1.1 GB. Its layers are all attention layers, so a copy
/// of a live sequence keeps each shared cell. It does not reason, so the
/// template keeps each earlier answer as the model wrote it, and the next
/// render of a history is the render that the cache holds.
///
/// The reference names a file inside a GGUF repository and no backend. The
/// router finds the backend from the files: a `.gguf` file loads with
/// llama.cpp.
private let ggufForkModel: ModelRef = "Qwen/Qwen2.5-1.5B-Instruct-GGUF/qwen2.5-1.5b-instruct-q4_k_m.gguf"

/// The flash and decision model of this suite: the small MLX instruct model
/// of `GGUFProfileIntegrationTests`, 680 MB. No test of this suite generates
/// on it.
private let ggufForkFlashModel: ModelRef = "mlx-community/Llama-3.2-1B-Instruct-4bit"

/// The working context of ``ggufForkProfile``, in tokens. llama.cpp loads a
/// GGUF model at a fixed context, and the sessions of this suite need few
/// tokens.
private let ggufForkContextTokens = 4096

/// The profile of this suite. Each fork runs on the standard slot of its
/// source.
private let ggufForkProfile = ProfileDefinition(
    name: "gguf-fork-prompt-cache",
    description: "A small attention-only GGUF standard model for the fork cache, and small companions.",
    standard: [ggufForkModel],
    flash: [ggufForkFlashModel],
    embedding: [RealModels.embedding],
    decision: [ggufForkFlashModel],
    context: ggufForkContextTokens
)

/// Gated real-model coverage for D205 (f) on a GGUF model (task ^h3xtekz).
///
/// The router calls no copy for a GGUF slot. On a partial hit of a live
/// record, the cache of FoundationModelsLlamaCpp copies the live sequence
/// into a free sequence of the same context, and the record of the source
/// stays live. A prompt that holds the whole record to the end of its last
/// user message takes the record: a fork at the last completed turn takes the
/// record of its source, and the next turn of the source then gets a copy of
/// the record of the fork.
///
/// ## What it proves
///
/// - The first call of a fork reuses the history of its source up to the cut
///   from the live record, for `.lastCompletedTurn` and
///   `.historyPosition(n)`. The bound is the tokens of the history that the
///   source left in the cache, less ``MeasuredAnswer/templateSeamTokens``.
/// - After the fork answered, the next turn of the source is a full hit: its
///   first call reuses the whole history of the source, so it does not
///   prefill its history again.
/// - After the source answered, the next turn of a fork at the last
///   completed turn is also a full hit: the copy for the source left the
///   record of the fork live with the whole history of the fork.
///
/// ## Why the coverage is gated
///
/// `LiveLLMContainerGGUFTests` in the unit target proves that the backend of
/// a GGUF container calls no copy. Only llama.cpp keeps a real live record.
/// The cache of the model is one cache for the whole process, so this suite
/// holds the GPU alone (`.exclusiveRealModel`). Each test has its own code
/// word, so a record that an earlier test left does not hold the history of
/// a later test, and only the records of the sessions of a test can satisfy
/// its bounds.
///
/// The suite has no time limit. A run ends when it ends, or when the caller
/// stops it.
@Suite(
    "Gated real-model coverage: a GGUF fork reuses the live record of its source (D205 (f))",
    .serialized,
    .exclusiveRealModel
)
struct GGUFForkPromptCacheIntegrationTests {
    /// The code word that the first prompt of the source of the fork at the
    /// last completed turn gives.
    private static let lastCompletedTurnCodeWord = "BRAVO-4"

    /// The code word that the first prompt of the source of the fork at a
    /// history position gives. Each test has its own code word, so the
    /// sessions of one test share only the instructions and a few words with
    /// a record that an earlier test left in the cache of the model.
    private static let historyPositionCodeWord = "CHARLIE-9"

    /// The prompt of the first turn of a source.
    ///
    /// - Parameter codeWord: The code word of the source.
    /// - Returns: The prompt.
    private static func firstSourcePrompt(codeWord: String) -> String {
        "My code word is \(codeWord). Reply with just OK."
    }

    /// The prompt of the second turn of each source.
    private static let secondSourcePrompt = "My favorite animal is the otter. Reply with just OK."

    /// The first prompt of each fork. The history of each fork holds the
    /// answer.
    ///
    /// The prompt is long, and its first word is not the first word of
    /// ``sourceFollowUpPrompt``. Thus the history of a fork is more than
    /// ``MeasuredAnswer/templateSeamTokens`` longer than the history that it
    /// shares with the next turn of its source.
    private static let forkPrompt =
        "Please tell me the code word that I gave you at the start of this conversation. Reply with just the code word."

    /// The prompt of the next turn of a fork, after its source answered.
    private static let forkFollowUpPrompt = "Say my code word one more time. Reply with just the code word."

    /// The prompt of the next turn of each source, after its fork answered.
    private static let sourceFollowUpPrompt = "What is my favorite animal? Reply with just the animal."

    /// The client that asks for each fork.
    private static let forkClientID = "gguf-fork-test"

    // MARK: - Fixture

    /// Resolves ``ggufForkProfile`` on a router over a pool of its own, and
    /// runs `body` with the standard model and the session directory. The
    /// body closes each session that it made, so the pool evicts each model
    /// at the end.
    ///
    /// - Parameter body: The test.
    /// - Throws: What the resolve or `body` throws.
    private static func withProfile(
        _ body: (RoutedLLM, RouterSessionDirectory) async throws -> Void
    ) async throws {
        try await IsolatedPoolRouter.withForkingRouter(
            label: "GGUFForkPromptCacheIntegrationTests", resolving: ggufForkProfile
        ) { isolated, profile in
            try await body(profile.standard, isolated.router.sessionDirectory)
        }
    }

    /// Makes a source on `model` that answered
    /// ``firstSourcePrompt(codeWord:)`` and then ``secondSourcePrompt``.
    ///
    /// - Parameters:
    ///   - model: The standard model.
    ///   - codeWord: The code word of the first prompt of the source.
    /// - Returns: The source and its two answers.
    /// - Throws: What an answer throws, or the `#require` failure for a
    ///   session that is not a Router session actor.
    private static func makeAnsweredSource(on model: RoutedLLM, codeWord: String) async throws -> AnsweredSource {
        try await AnsweredSource.answering(
            firstSourcePrompt(codeWord: codeWord), then: secondSourcePrompt, on: model.makeRoutedSessionActor())
    }

    // MARK: - The fork and the next turn of the source

    /// The production change that makes this test fail: a GGUF fork whose
    /// first prompt does not find the live record of its source, or a next
    /// turn of the source that takes and cuts the record of the fork instead
    /// of a copy of it (FoundationModelsLlamaCpp before c11b800), so the next
    /// turn of the fork prefills its own turn again.
    ///
    /// The fork holds the whole record of the source to the end of its last
    /// user message, so it takes the record. The next turn of the source
    /// holds the record of the fork only up to the prompt of the fork, so it
    /// gets a copy of the record, and the record of the fork stays live with
    /// the whole history of the fork. Before c11b800, the source took the
    /// record of the fork and cut it to the shared history. The first two
    /// bounds pass also then; only the bound of the next turn of the fork
    /// fails.
    @Test("a GGUF fork at the last completed turn reuses the history, and the next turns of the source and the fork are full hits")
    func aForkAtTheLastCompletedTurnReusesTheHistoryAndTheSourceStaysAFullHit() async throws {
        try await Self.withProfile { model, directory in
            let source = try await Self.makeAnsweredSource(on: model, codeWord: Self.lastCompletedTurnCodeWord)
            let fork = try await directory.liveFork(
                of: source.session, at: .lastCompletedTurn, clientID: Self.forkClientID)

            let forkAnswer = try await MeasuredAnswer.answer(to: Self.forkPrompt, on: fork)
            let sourceAnswer = try await MeasuredAnswer.answer(to: Self.sourceFollowUpPrompt, on: source.session)
            let forkFollowUp = try await MeasuredAnswer.answer(to: Self.forkFollowUpPrompt, on: fork)

            let sourceBound = MeasuredAnswer.reuseBound(of: try source.second.historyTokens())
            let forkBound = MeasuredAnswer.reuseBound(of: try forkAnswer.historyTokens())
            #expect(try forkAnswer.cachedTokensOfFirstCall() >= sourceBound)
            #expect(forkAnswer.reply.contains(Self.lastCompletedTurnCodeWord))
            #expect(try sourceAnswer.cachedTokensOfFirstCall() >= sourceBound)
            #expect(try forkFollowUp.cachedTokensOfFirstCall() >= forkBound)
            await closeEach([source.session, fork])
        }
    }

    /// The production change that makes this test fail: a GGUF fork whose
    /// first prompt does not find the live record of its source, or a fork
    /// that takes and cuts the record of its source, so the next turn of the
    /// source prefills its second turn again.
    ///
    /// The fork parts from the source inside the second user message, so the
    /// cache copies the live sequence of the source for the fork, and the
    /// record of the source stays live with its whole history.
    @Test("a GGUF fork at a history position reuses the history up to the position, and the next turn of the source is a full hit")
    func aForkAtAHistoryPositionReusesTheHistoryAndTheSourceStaysAFullHit() async throws {
        try await Self.withProfile { model, directory in
            let source = try await Self.makeAnsweredSource(on: model, codeWord: Self.historyPositionCodeWord)
            let position = try await source.session.positionOfSecondPrompt()
            let fork = try await directory.liveFork(
                of: source.session, at: .historyPosition(position), clientID: Self.forkClientID)

            let forkAnswer = try await MeasuredAnswer.answer(to: Self.forkPrompt, on: fork)
            let sourceAnswer = try await MeasuredAnswer.answer(to: Self.sourceFollowUpPrompt, on: source.session)

            let forkBound = MeasuredAnswer.reuseBound(of: try source.first.historyTokens())
            let sourceBound = MeasuredAnswer.reuseBound(of: try source.second.historyTokens())
            #expect(try forkAnswer.cachedTokensOfFirstCall() >= forkBound)
            #expect(forkAnswer.reply.contains(Self.historyPositionCodeWord))
            #expect(try sourceAnswer.cachedTokensOfFirstCall() >= sourceBound)
            await closeEach([source.session, fork])
        }
    }
}
