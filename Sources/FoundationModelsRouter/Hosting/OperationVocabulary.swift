// The operation-event vocabulary moved to FoundationModelsExtras (decision
// 2026-08-29): the canonical definitions live in that package's core module,
// in its `OperationEvents/` folder. This file re-exports them under the
// router's module, so router code and router consumers keep the same names.
import FoundationModelsExtras

/// The category of a posted `OperationEvent`. Canonical definition:
/// `FoundationModelsExtras.OperationEventKind`.
public typealias OperationEventKind = FoundationModelsExtras.OperationEventKind

/// A progress, completion, or elicitation event a long-running operation
/// posts through a connected `OperationEventSink`. Canonical definition:
/// `FoundationModelsExtras.OperationEvent`.
public typealias OperationEvent = FoundationModelsExtras.OperationEvent

/// How a completed operation run ended. Canonical definition:
/// `FoundationModelsExtras.OperationOutcome`.
public typealias OperationOutcome = FoundationModelsExtras.OperationOutcome

/// A destination `OperationEvent`s are posted to. The router implements this
/// one time, in `SessionOutbox`, and ``ToolContext/mount(_:op:as:postingTo:)``
/// takes one from a caller. Canonical definition:
/// `FoundationModelsExtras.OperationEventSink`.
public typealias OperationEventSink = FoundationModelsExtras.OperationEventSink

/// One tool call's live lifecycle record. Canonical definition:
/// `FoundationModelsExtras.ToolInvocationRecord`.
public typealias ToolInvocationRecord = FoundationModelsExtras.ToolInvocationRecord

/// A `Tool` that can produce a per-session instance of itself at fork time.
/// Canonical definition: `FoundationModelsExtras.ForkableTool`.
public typealias ForkableTool = FoundationModelsExtras.ForkableTool

/// Which interaction an `ElicitationRequest` asks the host to run.
/// Canonical definition: `FoundationModelsExtras.ElicitationMode`.
public typealias ElicitationMode = FoundationModelsExtras.ElicitationMode

/// An MCP-spec-shaped request for user input, posted by a running operation
/// and presented by a host. Canonical definition:
/// `FoundationModelsExtras.ElicitationRequest`.
public typealias ElicitationRequest = FoundationModelsExtras.ElicitationRequest

/// The `requestedSchema` of a form-mode `ElicitationRequest`. Canonical
/// definition: `FoundationModelsExtras.ElicitationRequestedSchema`.
public typealias ElicitationRequestedSchema = FoundationModelsExtras.ElicitationRequestedSchema

/// One property of an `ElicitationRequestedSchema`. Canonical definition:
/// `FoundationModelsExtras.ElicitationPrimitiveSchema`.
public typealias ElicitationPrimitiveSchema = FoundationModelsExtras.ElicitationPrimitiveSchema

/// The string formats the MCP elicitation subset allows. Canonical
/// definition: `FoundationModelsExtras.ElicitationStringFormat`.
public typealias ElicitationStringFormat = FoundationModelsExtras.ElicitationStringFormat

/// A free-text string property schema. Canonical definition:
/// `FoundationModelsExtras.ElicitationStringSchema`.
public typealias ElicitationStringSchema = FoundationModelsExtras.ElicitationStringSchema

/// A numeric property schema. Canonical definition:
/// `FoundationModelsExtras.ElicitationNumberSchema`.
public typealias ElicitationNumberSchema = FoundationModelsExtras.ElicitationNumberSchema

/// A boolean property schema. Canonical definition:
/// `FoundationModelsExtras.ElicitationBooleanSchema`.
public typealias ElicitationBooleanSchema = FoundationModelsExtras.ElicitationBooleanSchema

/// A single-select enum property schema. Canonical definition:
/// `FoundationModelsExtras.ElicitationSingleSelectSchema`.
public typealias ElicitationSingleSelectSchema = FoundationModelsExtras.ElicitationSingleSelectSchema

/// A multi-select enum property schema. Canonical definition:
/// `FoundationModelsExtras.ElicitationMultiSelectSchema`.
public typealias ElicitationMultiSelectSchema = FoundationModelsExtras.ElicitationMultiSelectSchema

/// One filled form value in an accepting `ElicitationResponse`. Canonical
/// definition: `FoundationModelsExtras.ElicitationValue`.
public typealias ElicitationValue = FoundationModelsExtras.ElicitationValue

/// The user's answer to an `ElicitationRequest`. Canonical definition:
/// `FoundationModelsExtras.ElicitationResponse`.
public typealias ElicitationResponse = FoundationModelsExtras.ElicitationResponse
