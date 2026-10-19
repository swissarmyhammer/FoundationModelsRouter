import FoundationModelsHooks
import Synchronization

@testable import FoundationModelsRouter

/// The recorded events of a recording hook visitor of a test, each with the
/// hook session of its context, in the order of delivery.
///
/// A recording visitor (``PromptHookTests/PromptRecordingVisitor``,
/// ``ToolHookTests/ToolRecordingVisitor``) holds one recorder, records each
/// event that it gets, and keeps its decisions for the pre events itself.
final class HookEventRecorder<Event: Sendable>: Sendable {
    /// The recorded events, each with the hook session of its context.
    private let recorded = Mutex<[(session: HookSession, event: Event)]>([])

    /// Signals after each recorded event.
    let changes = ChangeSignal()

    /// The recorded events, in the order of delivery.
    var events: [Event] {
        recorded.withLock { $0.map(\.event) }
    }

    /// The hook session of each recorded event, in the order of delivery.
    var sessions: [HookSession] {
        recorded.withLock { $0.map(\.session) }
    }

    /// Records one event, and signals the change.
    ///
    /// - Parameters:
    ///   - event: The event.
    ///   - session: The hook session of the context of the event.
    func record(_ event: Event, of session: HookSession) {
        recorded.withLock { $0.append((session, event)) }
        changes.signal()
    }
}
