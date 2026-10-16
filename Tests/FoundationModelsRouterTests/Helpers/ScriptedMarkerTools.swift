import FoundationModels
import FoundationModelsRouter
import Synchronization
import Testing

/// The call log a marker tool records into: every `value` argument the tool was
/// called with, in call order.
///
/// Shared by the marker tools below so the recording lives in exactly one
/// place, and a class so a test can read back the calls the very instance the
/// session mounted actually served.
final class MarkerToolCallLog: Sendable {
    /// Backing storage for ``calls``.
    ///
    /// A `Mutex` because the model call that invokes the tool and the test that
    /// reads the calls back are not the same task: the test reads only after
    /// its driving answer returned, but the write happens inside the SDK's own
    /// tool-calling task.
    private let recorded: Mutex<[String]> = Mutex([])

    /// Every `value` argument this log's tool was called with, in call order.
    var calls: [String] { recorded.withLock { $0 } }

    /// Records one call.
    ///
    /// - Parameter value: The `value` argument the call named.
    func record(_ value: String) {
        recorded.withLock { $0.append(value) }
    }
}

/// A test tool that records every step it was called for.
///
/// The marker tools below differ in `Output` type and in whether they fail, so
/// nothing about their `Tool` conformance lets a harness count executions
/// across a mixed set of them. This does: a harness holds `any
/// MarkerRecordingTool`, mounts it as `any Tool`, and reads back what really
/// ran.
protocol MarkerRecordingTool: Tool {
    /// Every step this tool was called for, in call order.
    var calledSteps: [String] { get }
}

/// A `FoundationModels.Tool` whose output carries a distinctive marker for the
/// step it was called with, and which records every step it was called for.
///
/// The marker is what makes the feedback claim assertable *by content*: the
/// scripted model has no way to produce `MARKER-7F3A-TWO` except by reading the
/// matching tool output out of the transcript it is handed, so a final answer
/// carrying it proves the output re-entered generation.
///
/// A class deliberately, so the test can read back the calls the very instance
/// the session mounted actually served.
final class MarkerEmittingTool: MarkerRecordingTool, Sendable {
    /// The default model-facing tool name, which is also the name a scripted
    /// call names when a script does not mount two of these at once.
    static let toolName = "marker-lookup"

    /// The `Tool` name requirement. Settable at construction so one script can
    /// mount two of these and ask for a call on each by name.
    let name: String

    /// The `Tool` description requirement. The scripted model picks its call by
    /// name and never reads this, but the SDK renders it into the tool
    /// definition it puts in the transcript, so it has to say what the tool is
    /// for.
    let description = "test-only tool that returns a distinctive marker for the step it is given"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// Every step this tool was called for, in call order.
    var calledSteps: [String] { callLog.calls }

    /// Creates the tool under a model-facing name.
    ///
    /// - Parameter name: The `Tool` name to answer to. Defaults to
    ///   ``toolName``.
    init(name: String = MarkerEmittingTool.toolName) {
        self.name = name
    }

    /// Records the step this call names and returns that step's marker output.
    ///
    /// The returned text is the only place the step's marker exists anywhere in
    /// the answer, so a reply carrying it can only have come from this output
    /// reaching the model's next generation.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: ``ScriptedToolFixture/marker(for:)`` for the named step.
    /// - Throws: Never — the tool cannot fail; `throws` comes from the `Tool`
    ///   requirement.
    func call(arguments: AmbientToolArguments) async throws -> String {
        callLog.record(arguments.value)
        return ScriptedToolFixture.marker(for: arguments.value)
    }
}

/// A `FoundationModels.Tool` that records its call and then always throws.
///
/// The counterpart of ``MarkerEmittingTool`` for the answer shape where a tool
/// call fails: the failure carries its own marker, so a test can tell by
/// content whether the error reached the model's next generation or the answer
/// simply proceeded as if nothing had been asked.
final class ThrowingMarkerTool: MarkerRecordingTool, Sendable {
    /// The failure every call raises.
    struct CallFailure: Error, CustomStringConvertible, Equatable {
        /// The step the failing call named.
        let step: String

        /// The failure text, carrying its own marker so an answer or a
        /// transcript entry quoting it is unmistakable.
        var description: String { ScriptedToolFixture.marker(for: "FAILED-" + step) }
    }

    /// The model-facing tool name a scripted call names to reach this tool.
    static let toolName = "marker-failure"

    /// The `Tool` name requirement, bound to ``toolName``.
    let name = ThrowingMarkerTool.toolName

    /// The `Tool` description requirement — see ``MarkerEmittingTool/description``
    /// for why a scripted fixture still carries one.
    let description = "test-only tool that always fails with a distinctive marker"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// Every step this tool was called for, in call order — recorded before the
    /// throw, so a test can prove the call really ran and did not merely get
    /// announced.
    var calledSteps: [String] { callLog.calls }

    /// Makes the error that a call throws, from the step that the call names.
    private let makeFailure: @Sendable (String) -> any Error

    /// Creates the tool.
    ///
    /// - Parameter makeFailure: Makes the error that a call throws, from the
    ///   step that the call names. The default makes a ``CallFailure``. A test
    ///   that gives `CancellationError` holds a cancellation that does not
    ///   come from a cancel of the task of the call.
    init(failingWith makeFailure: @escaping @Sendable (String) -> any Error = { CallFailure(step: $0) }) {
        self.makeFailure = makeFailure
    }

    /// Records the step this call names, then fails.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: Nothing — this entry point never returns a value.
    /// - Throws: The error that `makeFailure` makes for the named step, always.
    func call(arguments: AmbientToolArguments) async throws -> String {
        callLog.record(arguments.value)
        throw makeFailure(arguments.value)
    }
}

/// A `FoundationModels.Tool` that records its call, waits until the call is
/// cancelled, and then ends at that cancel with `CancellationError`.
///
/// The counterpart of ``ThrowingMarkerTool`` for a true cancellation: the
/// mount gives an ordinary failure to the model as a tool result, but it must
/// still throw a cancellation, so an answer that calls this tool must stop.
///
/// The mount throws a `CancellationError` again only when the task of the
/// call is cancelled. A `CancellationError` while the task of the call is not
/// cancelled, for example from a cancel of other work, is an ordinary failure
/// that the model reads. Thus this tool does not throw by itself. It waits
/// until a test stops the answer, as production does: the stop cancels the
/// model call, the model call cancels the task of the tool call, and that
/// cancel reaches this body.
final class CancellingMarkerTool: MarkerRecordingTool, Sendable {
    /// The model-facing tool name a scripted call names to reach this tool.
    static let toolName = "marker-cancelled"

    /// The `Tool` name requirement, bound to ``toolName``.
    let name = CancellingMarkerTool.toolName

    /// The `Tool` description requirement — see ``MarkerEmittingTool/description``
    /// for why a scripted fixture still carries one.
    let description = "test-only tool that waits until its call is cancelled"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// The event the call sends when it waits for its cancel. A test stops
    /// the answer only after this event, so the cancel reaches a call that
    /// runs.
    let entered = AwaitedEvent()

    /// Every step this tool was called for, in call order — recorded before the
    /// wait, so a test can prove the call really ran.
    var calledSteps: [String] { callLog.calls }

    /// Records the step this call names, sends ``entered``, and waits until
    /// the task of the call is cancelled.
    ///
    /// The wait is on a semaphore that nothing signals, so only a cancel ends
    /// it.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: Nothing — this entry point never returns a value.
    /// - Throws: `CancellationError` when the task of the call is cancelled.
    func call(arguments: AmbientToolArguments) async throws -> String {
        callLog.record(arguments.value)
        let neverSignalled = AsyncSemaphore(value: 0)
        try await neverSignalled.waitUnlessCancelled(onQueued: { self.entered.signal() })
        preconditionFailure("nothing signals the semaphore, so only a cancel ends the wait")
    }
}

// sah:allow duplication shares its recording shape with ThrowingMarkerTool, but the two outputs are different types — ThrowingMarkerTool returns String and so mounts in RunToCompletionRunner, this tool returns NonStringToolOutput and so mounts in ContextBindingTool — and a Tool conformance fixes one Output type, so no shared body can serve both mounting routes
/// A `FoundationModels.Tool` whose `Output` is not `String`, which records its
/// call and then always throws.
///
/// The non-`String` counterpart of ``ThrowingMarkerTool``: the mount sends it
/// down the binding-only ``ContextBindingTool`` route, so an answer calling it
/// proves that route also gives the failure to the model as a tool result.
final class ThrowingNonStringMarkerTool: MarkerRecordingTool, Sendable {
    /// The model-facing tool name a scripted call names to reach this tool.
    static let toolName = "marker-non-string-failure"

    /// The `Tool` name requirement, bound to ``toolName``.
    let name = ThrowingNonStringMarkerTool.toolName

    /// The `Tool` description requirement — see ``MarkerEmittingTool/description``
    /// for why a scripted fixture still carries one.
    let description = "test-only non-String-output tool that always fails with a distinctive marker"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// Every step this tool was called for, in call order — recorded before the
    /// throw, so a test can prove the call really ran.
    var calledSteps: [String] { callLog.calls }

    /// Records the step this call names, then fails.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: Nothing — this entry point never returns a value.
    /// - Throws: ``ThrowingMarkerTool/CallFailure`` for the named step, always.
    func call(arguments: AmbientToolArguments) async throws -> NonStringToolOutput {
        callLog.record(arguments.value)
        throw ThrowingMarkerTool.CallFailure(step: arguments.value)
    }
}

/// One failing tool a failure-delivery test mounts. Each row reaches a
/// different mount decorator, so a test that takes every row holds each route
/// a tool failure crosses.
struct FailingToolRow: Sendable, CustomTestStringConvertible {
    /// The row's name, which also names the case in test output.
    let name: String

    /// The model-facing name a scripted call names to reach the tool.
    let toolName: String

    /// Builds a fresh instance of the failing tool.
    let makeTool: @Sendable () -> any MarkerRecordingTool

    /// The name this row is reported under in test output.
    var testDescription: String { name }

    /// The failing tools, one for each mount decorator a failure crosses.
    static let everyMountRoute: [FailingToolRow] = [
        FailingToolRow(
            name: "a String-output tool (RunToCompletionRunner)",
            toolName: ThrowingMarkerTool.toolName,
            makeTool: { ThrowingMarkerTool() }),
        FailingToolRow(
            name: "a non-String-output tool (ContextBindingTool)",
            toolName: ThrowingNonStringMarkerTool.toolName,
            makeTool: { ThrowingNonStringMarkerTool() }),
    ]
}

/// The `@Generable` output ``StructuredMarkerTool`` returns, carrying one
/// step's marker as a structured value.
///
/// A `@Generable` output is what makes the SDK record the tool's
/// `.toolOutput` entry with a `.structure` segment instead of a `.text` one —
/// the segment shape the restore-fidelity suite must push through the full
/// disk round trip.
@Generable
struct StructuredMarkerOutput: Equatable {
    @Guide(description: "The distinctive marker for the step this call named.")
    var marker: String
}

/// A `FoundationModels.Tool` whose `Output` is a `@Generable` value, so its
/// `.toolOutput` entry carries a `.structure` segment.
///
/// The structured counterpart of ``MarkerEmittingTool``: same marker
/// vocabulary, but the output enters the transcript as structured content
/// rather than text, which is the shape the restore-fidelity tests need on
/// the full recorder -> disk -> reconstruction path.
final class StructuredMarkerTool: MarkerRecordingTool, Sendable {
    /// The model-facing tool name a scripted call names to reach this tool.
    static let toolName = "marker-structured"

    /// The `Tool` name requirement, bound to ``toolName``.
    let name = StructuredMarkerTool.toolName

    /// The `Tool` description requirement — see ``MarkerEmittingTool/description``
    /// for why a scripted fixture still carries one.
    let description = "test-only tool that returns a distinctive marker as structured output"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// Every step this tool was called for, in call order.
    var calledSteps: [String] { callLog.calls }

    /// Records the step this call names and returns that step's marker as a
    /// structured output.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: A ``StructuredMarkerOutput`` carrying
    ///   ``ScriptedToolFixture/marker(for:)`` for the named step.
    /// - Throws: Never — the tool cannot fail; `throws` comes from the `Tool`
    ///   requirement.
    func call(arguments: AmbientToolArguments) async throws -> StructuredMarkerOutput {
        callLog.record(arguments.value)
        return StructuredMarkerOutput(marker: ScriptedToolFixture.marker(for: arguments.value))
    }
}

// sah:allow duplication shares its recording shape with StructuredMarkerTool, but the two outputs are different types with different field lists — NonStringToolOutput(text:) is PromptRepresentable, StructuredMarkerOutput(marker:) is @Generable — and each tool exercises a different mounting route, so no shared function can hold the two bodies
/// A `FoundationModels.Tool` whose `Output` is not `String`, carrying the same
/// marker ``MarkerEmittingTool`` does.
///
/// ``ToolMounting/makeWrapped(tool:site:configuration:)`` sends a
/// non-`String`-output tool down its other path — the binding-only
/// ``ContextBindingTool`` rather than ``RunToCompletionRunner`` — so an answer calling this
/// tool exercises a mounting route the `String`-output fixtures never reach.
final class NonStringMarkerTool: MarkerRecordingTool, Sendable {
    /// The model-facing tool name a scripted call names to reach this tool.
    static let toolName = "marker-non-string"

    /// The `Tool` name requirement, bound to ``toolName``.
    let name = NonStringMarkerTool.toolName

    /// The `Tool` description requirement — see ``MarkerEmittingTool/description``
    /// for why a scripted fixture still carries one.
    let description = "test-only non-String-output tool that returns a distinctive marker"

    /// Backing store for ``calledSteps``.
    private let callLog = MarkerToolCallLog()

    /// Every step this tool was called for, in call order.
    var calledSteps: [String] { callLog.calls }

    /// Records the step this call names and returns that step's marker as a
    /// non-`String` output.
    ///
    /// - Parameter arguments: The call's decoded arguments; `value` is the step
    ///   name.
    /// - Returns: A ``NonStringToolOutput`` rendering
    ///   ``ScriptedToolFixture/marker(for:)`` for the named step.
    /// - Throws: Never — the tool cannot fail; `throws` comes from the `Tool`
    ///   requirement.
    func call(arguments: AmbientToolArguments) async throws -> NonStringToolOutput {
        callLog.record(arguments.value)
        return NonStringToolOutput(text: ScriptedToolFixture.marker(for: arguments.value))
    }
}
