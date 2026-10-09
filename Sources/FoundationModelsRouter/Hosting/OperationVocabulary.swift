// The operation-event vocabulary moved to FoundationModelsExtras (decision
// 2026-08-29): the canonical definitions live in that package's core module,
// in its `OperationEvents/` folder. This file re-exports them under the
// router's module, so router code and router consumers keep the same names.
import FoundationModelsExtras

// MARK: - Names that the Extras `Operations` module also declares

// The Extras `Operations` module declares its own typealias for each name
// below, and FoundationModelsAgents imports the router and `Operations` in one
// file (task ^cs9w81q). The router re-exports the ORIGINAL declaration of each
// of these names, not a second typealias. A file that imports only the router
// then sees the Extras declaration itself, so it can also name a nested type,
// for example `ToolMount.Mode`, in a public declaration. With a typealias,
// Swift rejects that nested name, because the file does not import
// FoundationModelsExtras. `OperationsNameClashTests` and
// `ToolMountPublicSurfaceTests` guard this.

// The category of a posted `OperationEvent`. Canonical definition:
// `FoundationModelsExtras.OperationEventKind`.
@_exported import enum FoundationModelsExtras.OperationEventKind

// A progress, completion, or elicitation event a long-running operation
// posts through a connected `OperationEventSink`. Canonical definition:
// `FoundationModelsExtras.OperationEvent`.
@_exported import struct FoundationModelsExtras.OperationEvent

// How a completed operation run ended. Canonical definition:
// `FoundationModelsExtras.OperationOutcome`.
@_exported import enum FoundationModelsExtras.OperationOutcome

// A destination `OperationEvent`s are posted to. The router implements this
// one time, in `SessionOutbox`, and `ToolContext.mount(_:op:as:postingTo:)`
// takes one from a caller. Canonical definition:
// `FoundationModelsExtras.OperationEventSink`.
@_exported import protocol FoundationModelsExtras.OperationEventSink

// A `Tool` that can produce a per-session instance of itself at fork time.
// Canonical definition: `FoundationModelsExtras.ForkableTool`.
@_exported import protocol FoundationModelsExtras.ForkableTool

// The mode and the timeout that a tool is mounted with. Canonical
// definition: `FoundationModelsExtras.ToolMount`.
@_exported import struct FoundationModelsExtras.ToolMount

// MARK: - Display event names that only the router re-exports

// The router re-exports the ORIGINAL declaration of each display name, not a
// typealias, for the same reason as the names above: a file that imports only
// the router can then name a nested type, for example
// `ToolDisplayEvent.Kind`, in a public declaration.
// `ToolDisplayEventPublicSurfaceTests` guards this.

// A display-only event of a tool: output or metadata for the client of the
// host, and never for the model. `SessionEvent.toolDisplay(_:)` carries it.
// Canonical definition: `FoundationModelsExtras.ToolDisplayEvent`.
@_exported import struct FoundationModelsExtras.ToolDisplayEvent

// One part of the display output of a tool: text, a diff, or JSON. Canonical
// definition: `FoundationModelsExtras.ToolDisplayContent`.
@_exported import enum FoundationModelsExtras.ToolDisplayContent

// MARK: - Operation event names that only the router re-exports

/// One tool call's live lifecycle record. Canonical definition:
/// `FoundationModelsExtras.ToolInvocationRecord`.
public typealias ToolInvocationRecord = FoundationModelsExtras.ToolInvocationRecord

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

// MARK: - Tool hosting

// The tool hosting moved to FoundationModelsExtras (decision 2026-09-26): the
// canonical definitions live in the `Hosting/` folder of that package's core
// module. The aliases below keep the router names, so a router user needs no
// source change, and a file that imports both modules finds one type for each
// name.

/// What a running tool can use: the run plane, the event sink and the
/// session of its call, and the stamps of its run. Canonical definition:
/// `FoundationModelsExtras.ToolContext`.
public typealias ToolContext = FoundationModelsExtras.ToolContext

/// Marks a `Tool` as a background tool, and gives its mount, its timeout and
/// its canceler. Canonical definition: `FoundationModelsExtras.BackgroundTool`.
public typealias BackgroundTool = FoundationModelsExtras.BackgroundTool

/// The failure that a mount makes, for example a timeout with no progress.
/// Canonical definition: `FoundationModelsExtras.ToolMountError`. The
/// `Operations` module does not declare this name, and it has no nested type,
/// so the typealias form stays.
public typealias ToolMountError = FoundationModelsExtras.ToolMountError

/// A `Tool` that the session calls one time before each submission.
/// Canonical definition: `FoundationModelsExtras.SubmissionBoundaryTool`.
public typealias SubmissionBoundaryTool = FoundationModelsExtras.SubmissionBoundaryTool

/// An error that tells that the work is gone with no observer. A run that
/// throws it settles as `lost`. Canonical definition:
/// `FoundationModelsExtras.LostRunError`.
public typealias LostRunError = FoundationModelsExtras.LostRunError

/// The kind of work of a background run. Canonical definition:
/// `FoundationModelsExtras.RunKind`.
public typealias RunKind = FoundationModelsExtras.RunKind

/// One open background run, with its identity and its latest progress.
/// Canonical definition: `FoundationModelsExtras.BackgroundRun`.
public typealias BackgroundRun = FoundationModelsExtras.BackgroundRun

/// The result of a wait for a background run. Canonical definition:
/// `FoundationModelsExtras.WaitOutcome`.
public typealias WaitOutcome = FoundationModelsExtras.WaitOutcome

/// The result of a cancel of a background run. Canonical definition:
/// `FoundationModelsExtras.CancelOutcome`.
public typealias CancelOutcome = FoundationModelsExtras.CancelOutcome

/// The control-plane answer of a background call: a pending run, or a run
/// that settled in its grace period. Canonical definition:
/// `FoundationModelsExtras.PendingRunEnvelope`.
public typealias PendingRunEnvelope = FoundationModelsExtras.PendingRunEnvelope

/// One record that a tool call attaches for its host. Canonical definition:
/// `FoundationModelsExtras.ToolCallAttachment`.
public typealias ToolCallAttachment = FoundationModelsExtras.ToolCallAttachment

/// The records that one tool call attached. Canonical definition:
/// `FoundationModelsExtras.ToolCallReport`.
public typealias ToolCallReport = FoundationModelsExtras.ToolCallReport

/// What an answer to a pending elicitation did. Canonical definition:
/// `FoundationModelsExtras.ElicitationAnswerDelivery`.
public typealias ElicitationAnswerDelivery = FoundationModelsExtras.ElicitationAnswerDelivery

/// What the completion of an accepted URL elicitation did. Canonical
/// definition: `FoundationModelsExtras.ElicitationCompletionDelivery`.
public typealias ElicitationCompletionDelivery = FoundationModelsExtras.ElicitationCompletionDelivery
