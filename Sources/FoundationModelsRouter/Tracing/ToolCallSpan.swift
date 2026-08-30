import Tracing

/// The one place a mounted tool's call is wrapped in its
/// ``RouterTracing/SpanName/tool`` span.
///
/// ``ToolMounting`` mounts every tool under exactly one of three outermost
/// decorators — ``RunToCompletionRunner``, ``BackgroundToolRunner`` or
/// ``ContextBindingTool`` — and those three share no `call` body, so each opens
/// the span for itself. Each opens it through this one helper, so the span's
/// name, its kind and its identity attributes are written once and no decorator
/// can drift from the other two.
///
/// The span nests in whatever span is current when the call runs, which is the
/// turn's own span whenever the model invokes the tool from inside the turn's
/// task. ``TokenCappingTool`` opens no span: it is a pass-through layer over one
/// of the three, and a span there would count a capped call twice.
///
/// ``RouterTracing/AttributeKey/toolOutcome`` is not written here. Only the
/// caller knows how the step its span covers ended, so the caller writes the
/// outcome onto the span this helper hands it.
enum ToolCallSpan {
    /// Runs `body` inside one tool span.
    ///
    /// - Parameters:
    ///   - tracer: The owning session's tracer, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - toolName: The model-facing name of the called tool.
    ///   - sessionID: The owning session's identity.
    ///   - runKind: The mount this call ran under.
    ///   - body: The call to measure, handed the open span so it can record the
    ///     outcome on it.
    /// - Returns: Whatever `body` returns.
    /// - Throws: Whatever `body` throws. `withSpan` records the error on the
    ///   span and raises it again.
    static func withSpan<Output>(
        tracer: (any Tracer)?,
        toolName: String,
        sessionID: ULID,
        runKind: RouterTracing.ToolRunKind,
        _ body: (any Span) async throws -> Output
    ) async throws -> Output {
        try await RouterTracing.tracer(explicit: tracer)
            .withSpan(RouterTracing.SpanName.tool, ofKind: .internal) { span in
                span.attributes[RouterTracing.AttributeKey.toolName] = toolName
                span.attributes[RouterTracing.AttributeKey.sessionId] = sessionID.description
                span.attributes[RouterTracing.AttributeKey.toolRunKind] = runKind.rawValue
                return try await body(span)
            }
    }

    /// Writes how the step a tool span covers ended onto that span.
    ///
    /// - Parameters:
    ///   - outcome: The outcome to record.
    ///   - span: The tool span to write it onto.
    static func record(outcome: OperationOutcome, on span: any Span) {
        span.attributes[RouterTracing.AttributeKey.toolOutcome] = outcome.rawValue
    }
}
