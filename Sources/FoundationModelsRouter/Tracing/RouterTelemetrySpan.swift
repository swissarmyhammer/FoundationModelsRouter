import Tracing

/// The spans of the router that record a failure without its content.
///
/// `withSpan` of swift-distributed-tracing calls `recordError` on the span when
/// its body throws, and swift-otel exports that error as an `exception` event
/// whose `exception.message` is the description of the error. The description
/// of an error can hold the caller's content: a path, a part of a prompt or a
/// tool argument. Thus a router span never gives an error of its body to
/// `withSpan`. The body gives its error back as a value, the span gets the
/// error status and the ``AttributeKey/errorType`` of the error, and the error
/// is thrown again after `withSpan` returns. This is the pattern of
/// `TracedCall.run` in FoundationModelsExtras.
extension RouterTelemetry {
    /// Gives `span` the error status and the ``AttributeKey/errorType`` of
    /// `error`.
    ///
    /// The span gets no error event, no status message and no description of
    /// the error, because the description of an error can hold the caller's
    /// content.
    ///
    /// - Parameters:
    ///   - error: The error that ended the work of the span.
    ///   - span: The span of the work.
    static func recordFailure(of error: any Error, on span: any Span) {
        span.setStatus(SpanStatus(code: .error))
        span.attributes[AttributeKey.errorType] = "\(type(of: error))"
    }

    /// Opens one span around `body`. When `body` throws, the span gets the
    /// error status and the ``AttributeKey/errorType`` of the error, and never
    /// the error itself.
    ///
    /// The synchronous form, for a caller whose work does not suspend.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - kind: The kind of the span.
    ///   - explicitTracer: The tracer of the owning handle, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - body: The work. It gets the open span.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`, after the span records its failure.
    static func withSpan<Output, Failure: Error>(
        _ spanName: String,
        ofKind kind: SpanKind,
        tracer explicitTracer: (any Tracer)?,
        _ body: (any Span) throws(Failure) -> Output
    ) throws(Failure) -> Output {
        let result: Result<Output, Failure> = tracer(explicit: explicitTracer)
            .withSpan(spanName, ofKind: kind) { span in
                do throws(Failure) {
                    return .success(try body(span))
                } catch {
                    recordFailure(of: error, on: span)
                    return .failure(error)
                }
            }
        return try result.get()
    }

    /// Opens one span around `body`. When `body` throws, the span gets the
    /// error status and the ``AttributeKey/errorType`` of the error, and never
    /// the error itself.
    ///
    /// The suspending form, for a caller whose work awaits. Swift has no
    /// effect polymorphism, so this form and the synchronous form above are a
    /// pair, as `withSpan` of swift-distributed-tracing is.
    ///
    /// - Parameters:
    ///   - spanName: The name of the span.
    ///   - kind: The kind of the span.
    ///   - explicitTracer: The tracer of the owning handle, or `nil` to read
    ///     `InstrumentationSystem.tracer` at call time.
    ///   - isolation: The isolation of the caller, which `body` runs on.
    ///   - body: The work. It gets the open span.
    /// - Returns: The value of `body`.
    /// - Throws: The error of `body`, after the span records its failure.
    static func withSpan<Output, Failure: Error>(
        _ spanName: String,
        ofKind kind: SpanKind,
        tracer explicitTracer: (any Tracer)?,
        isolation: isolated (any Actor)? = #isolation,
        _ body: (any Span) async throws(Failure) -> Output
    ) async throws(Failure) -> Output {
        let result: Result<Output, Failure> = await tracer(explicit: explicitTracer)
            .withSpan(spanName, ofKind: kind) { span in
                do throws(Failure) {
                    return .success(try await body(span))
                } catch {
                    recordFailure(of: error, on: span)
                    return .failure(error)
                }
            }
        return try result.get()
    }
}
