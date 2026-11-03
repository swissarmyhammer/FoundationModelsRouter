import FoundationModels
import FoundationModelsExtras
import Synchronization

/// The place where the final result of one hooked tool call arrives.
///
/// The hook layer (``ToolCallHooks``) binds one probe around the body of each
/// hooked tool call. A foreground call ends in the same task, so the
/// ``ToolResultWitness`` of the session finds the probe in ``current`` when
/// the call ends. A background call ends later, in a run task that the call
/// started: that task inherits the task-local value, so the witness finds the
/// same probe at the end of the run. Thus the result reaches its own call, and
/// the Router needs no map from an SDK call id to a completion token.
///
/// The result and its listener can arrive in any order. The probe gives the
/// result to the listener exactly one time.
final class ToolCallEndProbe: Sendable {
    /// The probe of the hooked tool call that runs in the current task, or
    /// `nil` outside a hooked tool call.
    @TaskLocal static var current: ToolCallEndProbe?

    /// Where the probe is between the result and its listener.
    private enum State {
        /// Neither the result nor a listener arrived.
        case waiting
        /// The result arrived first.
        case ended(OperationResult)
        /// A listener arrived first.
        case listening(@Sendable (OperationResult) -> Void)
        /// The listener got the result.
        case delivered
    }

    /// The state of the probe.
    private let state = Mutex(State.waiting)

    /// Gives the final result of the call to the probe. A second result is
    /// ignored.
    ///
    /// - Parameter result: How the call ended, and its own value.
    func ended(_ result: OperationResult) {
        let listener = state.withLock { state -> (@Sendable (OperationResult) -> Void)? in
            switch state {
            case .waiting:
                state = .ended(result)
                return nil
            case .listening(let listener):
                state = .delivered
                return listener
            case .ended, .delivered:
                return nil
            }
        }
        listener?(result)
    }

    /// Gives the final result to `listener` one time: at once when the call
    /// already ended, else when it ends. A second listener is ignored.
    ///
    /// - Parameter listener: What to do with the final result. It must
    ///   return at once and must not block.
    func whenEnded(_ listener: @escaping @Sendable (OperationResult) -> Void) {
        let result = state.withLock { state -> OperationResult? in
            switch state {
            case .waiting:
                state = .listening(listener)
                return nil
            case .ended(let result):
                state = .delivered
                return result
            case .listening, .delivered:
                return nil
            }
        }
        if let result { listener(result) }
    }
}

/// The ``ToolCallWitness`` that reads the end of each model-facing tool call
/// of a session, and gives it to the probe of the call (``ToolCallEndProbe``).
///
/// A site with a witness reports the end of each call: inner and outer, foreground
/// and background. The start is reported for inner calls only. So a token
/// that began is the token of an inner call, and the witness ignores its end.
/// An end of a token that never began is the end of the outer call, the call
/// that the model made.
///
/// The witness never changes, delays or fails a call.
final class ToolResultWitness: ToolCallWitness, Sendable {
    /// The completion tokens of the inner calls that began and did not end.
    private let innerTokens = Mutex<Set<String>>([])

    /// Remembers the token of an inner call.
    ///
    /// - Parameter call: The inner call that begins.
    func toolCallWillBegin(_ call: WitnessedToolCall) {
        guard let token = call.correlationID else { return }
        innerTokens.withLock { _ = $0.insert(token) }
    }

    /// Gives the result of the outer call to the probe of the call. The end
    /// of an inner call goes nowhere.
    ///
    /// - Parameters:
    ///   - call: The call that ended.
    ///   - result: How the call ended, and its own value.
    func toolCallDidEnd(_ call: WitnessedToolCall, result: OperationResult) {
        if let token = call.correlationID, innerTokens.withLock({ $0.remove(token) }) != nil { return }
        ToolCallEndProbe.current?.ended(result)
    }
}

/// A ``ToolCallWitness`` that gives each start and each end to every witness
/// of a list, in list order.
struct ToolCallWitnesses: ToolCallWitness {
    /// The witnesses that get each call.
    private let witnesses: [any ToolCallWitness]

    /// Makes a witness over `witnesses`.
    ///
    /// - Parameter witnesses: The witnesses that get each call.
    init(_ witnesses: [any ToolCallWitness]) {
        self.witnesses = witnesses
    }

    /// Gives the start of an inner call to each witness.
    ///
    /// - Parameter call: The inner call that begins.
    func toolCallWillBegin(_ call: WitnessedToolCall) {
        witnesses.forEach { $0.toolCallWillBegin(call) }
    }

    /// Gives the end of a call to each witness.
    ///
    /// - Parameters:
    ///   - call: The call that ended.
    ///   - result: How the call ended, and its own value.
    func toolCallDidEnd(_ call: WitnessedToolCall, result: OperationResult) {
        witnesses.forEach { $0.toolCallDidEnd(call, result: result) }
    }
}
