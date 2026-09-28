/// The telemetry names that FoundationModelsExtras writes for a tool call that
/// the router hosts.
///
/// The source of each name is `ExtrasTelemetry` in the Extras file
/// `Sources/FoundationModelsExtras/Telemetry/ExtrasTelemetry.swift`. Those
/// constants are internal to FoundationModelsExtras, so the tests cannot read
/// them and keep the same strings here, in one place. Change both together.
enum ExtrasTelemetryNames {
    /// The span name of one mounted tool call (`ExtrasTelemetry.SpanName.tool`).
    static let toolSpan = "FoundationModelsExtras.tool"

    /// The counter of the tool calls (`ExtrasTelemetry.MetricName.toolCalls`).
    static let toolCallsMetric = "FoundationModelsExtras.tool.calls"

    /// The dimension key of the tool name on the tool-call metrics
    /// (`ExtrasTelemetry.AttributeKey.toolName`).
    static let toolNameDimension = "tool.name"
}
