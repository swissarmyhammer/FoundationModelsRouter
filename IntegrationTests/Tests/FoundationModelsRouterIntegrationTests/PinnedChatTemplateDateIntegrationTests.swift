import Foundation
import FoundationModels
import FoundationModelsRouterTestSupport
import Testing

@testable import FoundationModelsRouter
@testable import FoundationModelsRouterRealModelSupport

/// The model whose chat template this suite holds the pin against.
///
/// Llama 3.1 8B, whose template reads `date_string`. 4.5 GB.
///
/// Not a Llama 3.2: on 2026-11-15 the 1B and the 3B rendered the pinned date
/// but did not answer it. The 1B answered `03 July 2024`, and the 3B answered
/// that it did not know the date. The 8B answered `26 July 2024`.
private let pinnedDateModel: ModelRef = "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit"

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

/// What the Llama 3.1 template writes ahead of the date it stamps.
///
/// The template writes `"Today Date: " + date_string + "\n\n"`, so this prefix
/// plus a date plus a line break is the whole line a render carries.
private let dateHeaderPrefix = "Today Date: "

/// The shape the clock fallback of the Llama 3.1 template writes the date in.
///
/// The template calls `strftime_now("%d %b %Y")` when nothing defines
/// `date_string`, so this format spells the line the clock would have written.
private let clockDateFormat = "dd MMM yyyy"

// MARK: - Suite

/// Gated real-model coverage for task ^g8rywv2: the pinned chat-template date
/// reaches the real template of Llama 3.1, which reads `date_string`.
///
/// The template reads the clock when nothing defines `date_string`:
///
/// ```
/// {%- if not date_string is defined %}
///     {%- if strftime_now is defined %}
///         {%- set date_string = strftime_now("%d %b %Y") %}
/// ```
///
/// ``FoundationModelsRouter/PinnedDateTokenizerLoader`` defines it, so a
/// render carries the pinned date and not today's.
///
/// ## Why the coverage is gated
///
/// The template is a file that ships with the weights. A stub tokenizer cannot
/// hold it: the hermetic suite
/// `Tests/FoundationModelsRouterTests/PinnedDateTokenizerLoaderTests.swift`
/// proves the loader STATES each name, and only a real render of the real
/// template proves the model READS one of them.
///
/// ## Until 2026-11-15
///
/// The suite ran on Muse-Glimmer-30B, whose template reads `current_date`
/// only when the conversation has no system message. Before task ^g8rywv2 the
/// loader stated `date_string` alone, and Glimmer answered the clock's date.
/// Muse Glimmer left the gated suites on 2026-11-15 (task ^467gchm). The
/// hermetic suite still holds that the loader states `current_date`.
@Suite(
    "Gated real-model coverage: the pinned chat-template date reaches Llama 3.1 (task ^g8rywv2)",
    .serialized,
    .exclusiveRealModel
)
struct PinnedChatTemplateDateIntegrationTests {
    /// The tag the answer test's wall-clock line opens with.
    ///
    /// Its own tag, and not the target's `gatedTest` one, so a grep that
    /// collects the per-test measurements of a run never picks up a phase
    /// line.
    private static let phaseLabel = "pinnedDatePhase"

    /// Loads ``pinnedDateModel`` with the date pinned and argmax decoding.
    ///
    /// - Returns: The loaded container and the pinned mode.
    /// - Throws: Whatever
    ///   ``RealModelContainer/load(ref:context:samplingMode:chatTemplateDate:)``
    ///   throws.
    private static func makeContainer() async throws -> RealModelContainer {
        try await RealModelContainer.load(
            ref: pinnedDateModel,
            samplingMode: pinnedDateSamplingMode,
            chatTemplateDate: pinnedDate
        )
    }

    /// The conversation a render is given, carrying no system message.
    ///
    /// The Llama 3.1 template writes its system header, and the date in it,
    /// for every conversation. This one holds one user message and nothing
    /// else, which is what a session vended with `instructions: nil` sends.
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

    /// The shapes in which the model can write a date in its answer: the shape
    /// of ``pinnedDate`` and ``clockDateFormat``, the ISO shape, and the
    /// spelled-out month.
    private static let answerDateFormats = ["d MMM yyyy", "yyyy-MM-dd", "MMMM d, yyyy", "d MMMM yyyy"]

    /// The calendar day that `text` names, in the shape of
    /// ``clockDateFormat``.
    ///
    /// The model reads the pinned date from its system header, but it can
    /// write that date in a different shape. On 2026-09-01 Muse Glimmer wrote
    /// `26 Jul 2024`, and on 2026-11-12 it wrote `2024-07-26` (task ^5hjddsq).
    /// Both are the pinned day. Thus the test compares calendar days, not
    /// strings.
    ///
    /// - Parameter text: A date in one of ``answerDateFormats``, with or
    ///   without a full stop at the end.
    /// - Returns: The day in the shape of ``clockDateFormat``, or `nil` when
    ///   `text` is in no known shape.
    private static func calendarDay(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "UTC")
        output.dateFormat = clockDateFormat
        for format in answerDateFormats {
            let input = DateFormatter()
            input.locale = output.locale
            input.timeZone = output.timeZone
            input.dateFormat = format
            if let date = input.date(from: trimmed) {
                return output.string(from: date)
            }
        }
        return nil
    }

    @Test("the render of the real template carries the pinned date, and not the clock's")
    func pinnedDateReachesTheRealTemplate() async throws {
        let loaded = try await Self.makeContainer()
        defer { await loaded.evict() }

        let modelContainer = try await #require(loaded.container.mlxModel).loadContainer()
        let rendered = try await modelContainer.perform { context in
            let tokenIds = try context.tokenizer.applyChatTemplate(
                messages: Self.conversationWithNoSystemMessage)
            return context.tokenizer.decode(tokenIds: tokenIds)
        }

        #expect(rendered.contains("\(dateHeaderPrefix)\(pinnedDate)\n"))
        #expect(!rendered.contains("\(dateHeaderPrefix)\(Self.clockDate())\n"))
    }

    @Test("a submission with no instructions answers the pinned date rather than today's")
    func theAnswerCarriesThePinnedDate() async throws {
        var loadDuration: Duration = .zero
        var submissionDuration: Duration = .zero
        defer {
            // swiftlint:disable:next no_direct_standard_out_logs  a grep of the run's output reads this line from standard out
            print("[\(Self.phaseLabel)] load=\(loadDuration) submission=\(submissionDuration)")
        }

        let loadStarted = ContinuousClock.now
        let loaded = try await Self.makeContainer()
        loadDuration = ContinuousClock.now - loadStarted
        defer { await loaded.evict() }

        // `instructions: nil` is what puts no system message into the
        // conversation, and the date branch of the template fires only then. A
        // session that states instructions gets no date at all, so it could not
        // measure the pin.
        let backend = try #require(
            loaded.container.makeSession(instructions: nil, samplingMode: loaded.samplingMode)
                as? MLXFoundationModelsSessionBackend
        )

        let startInstant = ContinuousClock.now
        let reply = try await backend.respond(
            to: "What is the current date? Answer with the date alone.",
            maxTokens: GatedRealModelBudget.responseTokenCeiling
        )
        submissionDuration = ContinuousClock.now - startInstant
        let answer = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        // swiftlint:disable:next no_direct_standard_out_logs  a red run shows on standard out what the model answered
        print("[\(Self.phaseLabel)] reply=\(answer)")

        // The model reads the date out of the system header the template wrote,
        // so the answer names the pinned day, in one shape or the other. A date
        // that moved would move this answer with it, which is what makes the
        // assertion a measurement of the pin rather than of the model.
        let answeredDay = try #require(Self.calendarDay(of: answer), "reply: \(answer)")
        #expect(answeredDay == Self.calendarDay(of: pinnedDate))
        #expect(answeredDay != Self.clockDate())
    }
}
