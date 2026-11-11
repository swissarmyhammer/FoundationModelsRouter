import FoundationModelsDecision
import FoundationModelsRouterTestSupport
import InMemoryTracing
import Testing
import Tracing

@testable import FoundationModelsRouter

/// Exercises card ^a9dkcbk: each batch of questions that a session of a
/// ``RoutedDecider`` sends to its model opens one OpenTelemetry span.
///
/// A decision writes nothing to the transcript, thus a span is the one signal
/// of a decision. This suite holds the contract of that span: the operation
/// name, the span kind, the three attributes, the error status and the error
/// type on a failure, the prewarm that opens no span, the no-op tracer when no
/// backend is bootstrapped, and the rule that no attribute carries the state,
/// a question, an option or an answer.
///
/// The handle is built by hand over a stub decision model and an
/// `InMemoryTracer`, thus the suite needs no network, no model and no
/// bootstrapped tracing backend.
@Suite("Decision telemetry")
struct DecisionTelemetryTests {
    // MARK: - Fixed values

    /// The span name of each decide call.
    private static let spanName = "FoundationModelsRouter.decide"

    /// The name of each attribute of the decide span.
    private static let attributeNames = ["router.id", "model.ref", "decision.question_count"]

    /// The model reference of the handle.
    private static let ref: ModelRef = "org/decider-traced"

    /// The text of the state. A distinctive marker, thus an attribute that
    /// holds it cannot hold another value.
    private static let stateText = "state-marker-5b8e"

    /// The instructions of each question.
    private static let instructions = "question-marker-2c71"

    /// The text of the criterion for "yes".
    private static let whenTrue = "criterion-yes-marker-7a13"

    /// The text of the criterion for "no".
    private static let whenFalse = "criterion-no-marker-e604"

    /// The name of the option that the stub model chooses.
    private static let chosenOption = "option-marker-9d04"

    /// The name of the option that the stub model does not choose.
    private static let otherOption = "option-marker-41bf"

    /// The description of the chosen option.
    private static let optionDescription = "option-description-marker-c38a"

    /// The levels of the score question. The stub model gives the lowest
    /// level, and the answer holds each level as its legend.
    private static let levels = ["level-marker-0f5d", "level-marker-b927"]

    /// The questions of one batch: one question of each kind, each with its
    /// own marker text.
    private static let questions: [Question] = [
        .binary(instructions: instructions, criteria: BinaryCriteria(whenTrue: whenTrue, whenFalse: whenFalse)),
        .choice(
            instructions: instructions,
            options: [ChoiceOption(chosenOption, description: optionDescription), ChoiceOption(otherOption)]),
        .score(instructions: instructions, levels: levels),
    ]

    /// Each text that no attribute of the span may hold: the state, the
    /// question texts, the option texts and the answers.
    private static var markers: [String] {
        [
            stateText, instructions, whenTrue, whenFalse, chosenOption, otherOption, optionDescription,
            String(StubDecisionModel.binaryProbability),
        ] + levels
    }

    // MARK: - Stubs

    /// The failure that a stub executor throws.
    private enum StubFailure: Error {
        /// The decide call failed (``UnavailableDecisionContainer``).
        case decide

        /// The prewarm call reached the stub executor.
        case prewarm
    }

    /// A decision model whose executor gives one fixed answer for each
    /// question.
    private struct StubDecisionModel: DecisionModel {
        /// The probability of "yes" that the stub gives for a yes-or-no
        /// question. A distinctive value, thus an attribute that holds it can
        /// be found.
        static let binaryProbability = 0.618034

        /// The model reference, as text.
        var modelID: String { DecisionTelemetryTests.ref.stringValue }

        /// No limits.
        var capabilities: DecisionCapabilities { DecisionCapabilities() }

        /// Makes the executor of one session.
        ///
        /// - Returns: The stub executor.
        func makeExecutor() -> any DecisionModelExecutor {
            StubDecisionExecutor()
        }
    }

    /// The executor of ``StubDecisionModel``.
    private struct StubDecisionExecutor: DecisionModelExecutor {
        /// Throws ``StubFailure/prewarm``, thus a test can see that the
        /// prewarm reached this executor.
        ///
        /// - Parameter state: The state. Unread.
        /// - Throws: ``StubFailure/prewarm`` always.
        func prewarm(for state: DecisionState) async throws {
            throw StubFailure.prewarm
        }

        /// Gives the first option or the lowest level for each question, with
        /// all of the probability on it, and ``StubDecisionModel/binaryProbability``
        /// for a yes-or-no question.
        ///
        /// - Parameters:
        ///   - questions: The questions.
        ///   - state: The state. Unread.
        /// - Returns: One answer for each question.
        func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
            DecisionSession.Response(
                modelID: DecisionTelemetryTests.ref.stringValue, answers: questions.map(Self.answer(to:)))
        }

        /// Gives the fixed answer to one question.
        ///
        /// - Parameter question: The question.
        /// - Returns: The answer.
        private static func answer(to question: Question) -> Answer {
            switch question {
            case .binary:
                return .binary(probability: StubDecisionModel.binaryProbability)
            case .choice(_, let options):
                let names = options.map(\.name)
                return .choice(name: names[0], probabilities: certainFirst(names), confidence: 1)
            case .score(_, let levels):
                return .score(
                    value: 0, probabilities: levels.indices.map { $0 == 0 ? 1 : 0 }, legend: levels, confidence: 1)
            }
        }

        /// Puts all of the probability on the first name.
        ///
        /// - Parameter names: The option names.
        /// - Returns: A probability of 1 for the first name and 0 for each
        ///   other name.
        private static func certainFirst(_ names: [String]) -> [String: Double] {
            Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0 == 0 ? 1 : 0) })
        }
    }

    /// A decision container over ``StubDecisionModel``.
    private struct StubContainer: LoadedDecisionContainer {
        /// The stub model.
        var decisionModel: any DecisionModel { StubDecisionModel() }
    }

    // MARK: - Helpers

    /// Makes a decision handle over `container`.
    ///
    /// - Parameters:
    ///   - container: The decision container of the handle.
    ///   - routerId: The recording root id of the router of the handle.
    ///   - tracer: The tracer of the handle, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    /// - Returns: The handle.
    private static func makeDecider(
        over container: any LoadedDecisionContainer = StubContainer(),
        routerId: ULID = ULID(),
        tracer: (any Tracer)?
    ) -> RoutedDecider {
        HandBuiltProfileFixtures.makeDecider(chosen: ref, container: container, routerId: routerId, tracer: tracer)
    }

    /// Sends ``questions`` in one batch, through a session about
    /// ``stateText`` of a handle that reports to `tracer`.
    ///
    /// - Parameters:
    ///   - tracer: The tracer of the handle.
    ///   - routerId: The recording root id of the router of the handle.
    /// - Returns: The response of the session.
    /// - Throws: Whatever the session throws.
    @discardableResult
    private static func decideQuestions(
        reportingTo tracer: InMemoryTracer,
        routerId: ULID = ULID()
    ) async throws -> DecisionSession.Response {
        try await makeDecider(routerId: routerId, tracer: tracer)
            .makeSession(state: .text(stateText))
            .decide(questions)
    }

    /// The one finished decide span that `tracer` holds.
    ///
    /// - Parameter tracer: The tracer that the work reported to.
    /// - Returns: The span.
    /// - Throws: An issue when `tracer` holds no decide span or more than one.
    private static func onlyDecideSpan(reportedTo tracer: InMemoryTracer) throws -> FinishedInMemorySpan {
        let spans = tracer.finishedSpans(named: spanName)
        try #require(spans.count == 1)
        return spans[0]
    }

    // MARK: - Tests

    /// One decide call gives one finished span with the decide name.
    @Test("one decide call gives one finished decide span")
    func decideGivesOneSpan() async throws {
        let tracer = InMemoryTracer()
        try await Self.decideQuestions(reportingTo: tracer)
        #expect(tracer.finishedSpans(named: Self.spanName).count == 1)
    }

    /// The decide span is of kind client, as the embed span is.
    @Test("the decide span is of kind client")
    func decideSpanIsClient() async throws {
        let tracer = InMemoryTracer()
        try await Self.decideQuestions(reportingTo: tracer)
        #expect(try Self.onlyDecideSpan(reportedTo: tracer).kind == .client)
    }

    /// The decide span holds exactly the router id, the model reference and
    /// the count of the questions of the batch.
    @Test("the decide span holds exactly the router id, the model ref and the question count")
    func decideSpanHoldsTheThreeAttributes() async throws {
        let tracer = InMemoryTracer()
        let routerId = ULID()
        try await Self.decideQuestions(reportingTo: tracer, routerId: routerId)

        let expected: SpanAttributes = [
            "router.id": .string(routerId.description),
            "model.ref": .string(Self.ref.stringValue),
            "decision.question_count": .int64(Int64(Self.questions.count)),
        ]
        #expect(try Self.onlyDecideSpan(reportedTo: tracer).attributes == expected)
    }

    /// The traced model gives the response of the inner model with no change.
    @Test("a traced session gives the response of the inner model")
    func tracedSessionGivesTheInnerResponse() async throws {
        let expected = try await DecisionSession(model: StubDecisionModel(), state: .text(Self.stateText))
            .decide(Self.questions)
        #expect(try await Self.decideQuestions(reportingTo: InMemoryTracer()) == expected)
    }

    /// A decide call that throws gives the error status and the type of the
    /// error on its span, and the error goes to the caller.
    @Test("a decide call that throws records the error type on its span")
    func failedDecideRecordsTheErrorType() async throws {
        let tracer = InMemoryTracer()
        let session = Self.makeDecider(
            over: UnavailableDecisionContainer(ref: Self.ref, error: StubFailure.decide), tracer: tracer)
            .makeSession(state: .text(Self.stateText))

        await #expect(throws: StubFailure.decide) {
            _ = try await session.decide(Self.questions)
        }

        #expect(try Self.onlyDecideSpan(reportedTo: tracer).failureType == "\(StubFailure.self)")
    }

    /// No attribute value of the decide span holds the state, a question
    /// text, an option text or an answer.
    ///
    /// `SpanAttributes` is not a sequence. Thus the test reads the value of
    /// each name in ``attributeNames``, and it requires that these values are
    /// all of the attributes of the span.
    @Test("no decide span attribute holds the state, a question, an option or an answer")
    func decideSpanHoldsNoContent() async throws {
        let tracer = InMemoryTracer()
        try await Self.decideQuestions(reportingTo: tracer)

        let attributes = try Self.onlyDecideSpan(reportedTo: tracer).attributes
        let values = Self.attributeNames.compactMap { attributes.get($0) }
        let rendered = values.map { String(describing: $0) }.joined(separator: "\n")
        try #require(!values.isEmpty)
        try #require(values.count == attributes.count)
        #expect(
            RecordingRedactionScan.findings(in: rendered, file: Self.spanName, patterns: Self.markers).isEmpty)
    }

    /// A prewarm reaches the inner executor and opens no span.
    @Test("a prewarm reaches the inner executor and opens no span")
    func prewarmOpensNoSpan() async throws {
        let tracer = InMemoryTracer()
        let session = Self.makeDecider(tracer: tracer).makeSession(state: .text(Self.stateText))

        await #expect(throws: StubFailure.prewarm) {
            try await session.prewarm()
        }

        #expect(tracer.finishedSpans.isEmpty)
    }

    /// With no tracer on the handle and no bootstrapped backend, the decide
    /// span goes to the no-op tracer, and the session still answers.
    @Test("with no tracer and no backend, the decide span goes to the no-op tracer")
    func unbootstrappedTracerIsNoOp() async throws {
        let decider = Self.makeDecider(tracer: nil)
        let response = try await decider.makeSession(state: .text(Self.stateText)).decide(Self.questions)

        #expect(RouterTelemetry.tracer(explicit: decider.tracer) is NoOpTracer)
        #expect(response.answers.count == Self.questions.count)
    }
}
