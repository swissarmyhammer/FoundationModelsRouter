import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model whose chat template this suite holds the pin against.
///
/// `RealModels.standard` is `mlx-community/Muse-Glimmer-30B-4bit`, and
/// `RealModels.flash` is the same repository. It is the model every other gated
/// suite of this target loads for the `.standard` slot.
private let pinnedDateModel: ModelRef = RealModels.standard

/// The decoding the container this suite loads is pinned to.
///
/// Argmax. The provider default draws at temperature `0.6` from MLX's
/// process-global PRNG, which seeds itself from the clock, so the answer would
/// be a fresh sample on every run and a red run would say nothing. Argmax
/// consumes no randomness, so what is left that can move the answer is the
/// PROMPT — which is the thing this suite measures.
private let pinnedDateSamplingMode: GenerationOptions.SamplingMode = .greedy

/// The calendar date this suite pins into ``pinnedDateModel``'s prompt.
///
/// The value comes from ``RealModelContainer/chatTemplateFallbackDate``, which
/// states why the constant is a template's own fallback rather than a date
/// chosen because it made a run green.
private let pinnedDate = RealModelContainer.chatTemplateFallbackDate

/// What the Muse Glimmer template writes ahead of the date it stamps.
///
/// The template writes `'\nCurrent date: ' + <date> + '.'`, so this prefix plus
/// a date plus a full stop is the whole line a render carries.
private let currentDateHeaderPrefix = "Current date: "

/// The shape Muse Glimmer's own clock fallback writes the date in.
///
/// The template calls `strftime_now('%Y-%m-%d')` when nothing defines
/// `current_date`, so this format spells the line the clock would have written.
private let clockDateFormat = "yyyy-MM-dd"

// MARK: - Suite

/// Gated real-model coverage for task ^g8rywv2: the pinned chat-template date
/// reaches Muse Glimmer, whose template reads `current_date`.
///
/// ## What was broken
///
/// ``FoundationModelsRouter/PinnedDateTokenizerLoader`` pinned one name,
/// `date_string`. That is the Llama family's name. Muse Glimmer reads
/// `current_date`, inside the branch it takes when the conversation carries NO
/// system message:
///
/// ```
/// {%- if current_date is defined and current_date -%}
///     {{- '\nCurrent date: ' + current_date + '.' -}}
/// {%- elif strftime_now is defined -%}
///     {{- '\nCurrent date: ' + strftime_now('%Y-%m-%d') + '.' -}}
/// {%- endif -%}
/// ```
///
/// So a suite that drove this model with `instructions: nil` took the clock
/// into its prompt however hard it pinned the date. The loader now states every
/// name it knows, and this suite is what holds it to that against the real
/// template and the real weights.
///
/// ## Why the coverage is gated
///
/// The defect lives in a template file that ships with the weights. A stub
/// tokenizer cannot hold it: the hermetic suite
/// `Tests/FoundationModelsRouterTests/PinnedDateTokenizerLoaderTests.swift`
/// proves the loader STATES both names, and only a real render of the real
/// template proves the model READS one of them.
///
/// ## The measurement of 2026-09-01
///
/// One binary, only `TZ` changed. `Pacific/Midway` stood on 2026-09-01 and
/// `Pacific/Kiritimati` on 2026-09-02 — two calendar dates, not two offsets of
/// one date.
///
/// | the pin | 2026-09-01 | 2026-09-02 |
/// |---|---|---|
/// | both names | `26 Jul 2024` | `26 Jul 2024` |
/// | `date_string` alone | `2026-09-01` | not measured |
///
/// The cells hold what the model answered when it was asked for the current
/// date. The second row is the loader as it stood before this suite: the render
/// carried `Current date: 2026-09-01.`, both assertions of the render test went
/// red, and the model read the clock's date straight out of its own system
/// header.
///
/// The turn measures 26.2 to 26.3 seconds and the load 3.2, so the suite runs
/// at 28 percent of ``integrationTestBudgetMinutes``. The render test needs no
/// generation and measures 3.5.
@Suite(
    "Gated real-model coverage: the pinned chat-template date reaches Muse Glimmer (task ^g8rywv2)",
    .serialized,
    .timeLimit(.minutes(integrationTestBudgetMinutes)),
    .exclusiveRealModel
)
struct PinnedChatTemplateDateIntegrationTests {
    /// The tag the answer test's wall-clock line opens with.
    ///
    /// Its own tag, and not the target's `gatedTest` one, so a grep that
    /// collects the run table's per-test measurements never picks up a phase
    /// line. See ``integrationTestBudgetMinutes`` for that table.
    private static let phaseLabel = "pinnedDatePhase"

    /// Loads ``pinnedDateModel`` with the date pinned and argmax decoding.
    ///
    /// - Returns: The loaded container.
    /// - Throws: Whatever
    ///   ``RealModelContainer/load(ref:context:samplingMode:chatTemplateDate:)``
    ///   throws.
    private static func makeContainer() async throws -> MLXFoundationModelsContainer {
        try await RealModelContainer.load(
            ref: pinnedDateModel,
            samplingMode: pinnedDateSamplingMode,
            chatTemplateDate: pinnedDate
        )
    }

    /// The conversation a render is given, carrying no system message.
    ///
    /// The date branch of the template fires only when nothing in the
    /// conversation is a system message, which is what a session vended with
    /// `instructions: nil` sends. So this conversation holds one user turn and
    /// nothing else.
    private static let conversationWithNoSystemMessage: [[String: any Sendable]] = [
        ["role": "user", "content": "Say 'hi' briefly."]
    ]

    /// The date the clock would have written into the render.
    ///
    /// - Returns: today's date, in the shape the template's own
    ///   `strftime_now` call writes.
    private static func clockDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = clockDateFormat
        return formatter.string(from: Date())
    }

    @Test("the render of the real template carries the pinned date, and not the clock's")
    func pinnedDateReachesTheRealTemplate() async throws {
        let container = try await Self.makeContainer()

        let modelContainer = try await container.model.loadContainer()
        let rendered = try await modelContainer.perform { context in
            let tokenIds = try context.tokenizer.applyChatTemplate(
                messages: Self.conversationWithNoSystemMessage)
            return context.tokenizer.decode(tokenIds: tokenIds)
        }

        #expect(rendered.contains("\(currentDateHeaderPrefix)\(pinnedDate)."))
        #expect(!rendered.contains("\(currentDateHeaderPrefix)\(Self.clockDate())."))

        await container.model.evict()
    }

    @Test("a turn with no instructions answers the pinned date rather than today's")
    func theAnswerCarriesThePinnedDate() async throws {
        var loadDuration: Duration = .zero
        var turnDuration: Duration = .zero
        defer {
            // swiftlint:disable:next no_direct_standard_out_logs  the run table's grep reads this line from standard out
            print("[\(Self.phaseLabel)] load=\(loadDuration) turn=\(turnDuration)")
        }

        let loadStarted = ContinuousClock.now
        let container = try await Self.makeContainer()
        loadDuration = ContinuousClock.now - loadStarted

        // `instructions: nil` is what puts no system message into the
        // conversation, and the date branch of the template fires only then. A
        // session that states instructions gets no date at all, so it could not
        // measure the pin.
        let backend = try #require(
            container.makeSession(instructions: nil) as? MLXFoundationModelsSessionBackend
        )

        let turnStarted = ContinuousClock.now
        let reply = try await backend.respond(
            to: "What is the current date? Answer with the date alone.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        turnDuration = ContinuousClock.now - turnStarted
        let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // swiftlint:disable:next no_direct_standard_out_logs  a red run shows on standard out what the model answered
        print("[\(Self.phaseLabel)] reply=\(answer)")

        // The model reads the date out of the system header the template wrote,
        // so the answer IS the pinned value. A date that moved would move this
        // answer with it, which is what makes the assertion a measurement of
        // the pin rather than of the model.
        #expect(answer == pinnedDate)

        await container.model.evict()
    }
}
