import FoundationModelsExtras

/// The completion of an accepted URL-mode question of a run, carried by
/// ``SessionEvent/elicitationCompleted(_:)`` (task ^rkh6k6m).
///
/// A run asks a URL-mode question through `ToolContext.elicit(_:)`, and the
/// session sends ``SessionEvent/elicitationRequested(_:)``. The client
/// accepts it (``RoutedSession/respond(elicitationId:response:)``), and the
/// run waits until the out-of-band flow of the URL completes. The flow
/// completes through ``RoutedSession/complete(elicitationId:)``, or through
/// `ToolContext.complete(elicitationId:)` of the tool that asked. Then the run
/// resumes, and the session sends this completion, so that the client can
/// remove the question from its view.
public struct ElicitationCompletion: Sendable, Equatable {
    /// The id of the question: the same ``ElicitationRequest/elicitationId``
    /// as in the ``SessionEvent/elicitationRequested(_:)`` of the question.
    public let elicitationId: ULID

    /// Creates the completion of a question.
    ///
    /// - Parameter elicitationId: The id of the question.
    public init(elicitationId: ULID) {
        self.elicitationId = elicitationId
    }
}
