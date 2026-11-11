import FoundationModelsDecision
import Tracing

/// A ``DecisionModel`` that opens one span for each batch of questions that
/// it sends to an inner decision model.
///
/// `DecisionSession` is a type of FoundationModelsDecision, thus the router
/// cannot open a span around its methods. The router wraps the model of the
/// session instead: ``RoutedModel/makeSession(state:)`` makes each session
/// over this model, and the executor of this model opens the span around each
/// call to the executor of the inner model.
///
/// The model identifier and the capabilities are those of the inner model,
/// thus a session over this model checks the same limits and reports the same
/// model.
///
/// ``RoutedModel/makeSession(state:)`` states the contract of the span: its
/// name, its kind, its three attributes and the failure record. The span opens
/// through ``RouterTelemetry/withSpan(_:ofKind:tracer:isolation:_:)``, thus a
/// failure records the error type and never the error description. A prewarm
/// opens no span.
///
/// No state text, no question text, no option text and no answer value ever
/// reaches the span. The span gets only the router id, the model reference and
/// the count of the questions.
struct TracedDecisionModel: DecisionModel {
    /// The model that answers the questions.
    let inner: any DecisionModel

    /// The recording root id of the router that resolved the model.
    let routerId: ULID

    /// The chosen model reference of the decision handle.
    let modelRef: ModelRef

    /// The tracer that a decide call opens its span through, or `nil` to read
    /// `InstrumentationSystem.tracer` at call time.
    let tracer: (any Tracer)?

    /// The model identifier of the inner model.
    var modelID: String { inner.modelID }

    /// The capabilities of the inner model.
    var capabilities: DecisionCapabilities { inner.capabilities }

    /// Makes an executor that wraps one executor of the inner model.
    ///
    /// - Returns: A new executor.
    func makeExecutor() -> any DecisionModelExecutor {
        TracedDecisionModelExecutor(model: self, inner: inner.makeExecutor())
    }
}

/// The executor of ``TracedDecisionModel``: it opens the decide span around
/// each decide call of the inner executor.
struct TracedDecisionModelExecutor: DecisionModelExecutor {
    /// The traced model that made this executor. It holds the values of the
    /// span attributes and the tracer.
    let model: TracedDecisionModel

    /// The executor of the inner model.
    let inner: any DecisionModelExecutor

    /// Prewarms the inner executor. This call opens no span.
    ///
    /// - Parameter state: The state that the questions will be about.
    /// - Throws: Any error of the inner executor.
    func prewarm(for state: DecisionState) async throws {
        try await inner.prewarm(for: state)
    }

    /// Answers a batch of questions through the inner executor, inside one
    /// decide span.
    ///
    /// - Parameters:
    ///   - questions: The questions.
    ///   - state: The state that the questions are about.
    /// - Returns: The response of the inner executor.
    /// - Throws: Any error of the inner executor.
    func decide(_ questions: [Question], about state: DecisionState) async throws -> DecisionSession.Response {
        try await RouterTelemetry
            .withSpan(RouterTelemetry.SpanName.decide, ofKind: .client, tracer: model.tracer) { span in
                span.attributes[RouterTelemetry.AttributeKey.routerId] = model.routerId.description
                span.attributes[RouterTelemetry.AttributeKey.modelRef] = model.modelRef.stringValue
                span.attributes[RouterTelemetry.AttributeKey.decisionQuestionCount] = questions.count
                return try await inner.decide(questions, about: state)
            }
    }
}
