import InMemoryTracing
import Tracing

extension FinishedInMemorySpan {
    /// The attribute key of the type of the error that ended a traced call
    /// (`ExtrasTelemetry.AttributeKey.errorType` in FoundationModelsExtras).
    /// Change both together.
    static let errorTypeAttribute = "error.type"

    /// The type name that the span records for the error that ended its call,
    /// or `nil` when the span has no error status.
    ///
    /// A traced call records only the type of its error, never the error
    /// itself, because the description of an error can hold the caller's
    /// content. A test reads the failure through the error status and this
    /// attribute.
    var failureType: String? {
        guard status?.code == .error else { return nil }
        guard case .string(let type)? = attributes.get(Self.errorTypeAttribute) else { return nil }
        return type
    }
}
