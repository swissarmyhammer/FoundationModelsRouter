import FoundationModelsExtras

/// The end of a question of a run that ended with no answer of the client,
/// carried by ``SessionEvent/elicitationEnded(_:)`` (task ^fqb5rjr).
///
/// A run asks a question through `ToolContext.elicit(_:)`, and the session
/// sends ``SessionEvent/elicitationRequested(_:)``. The question can end in two
/// ways. The client answers it (``RoutedSession/respond(elicitationId:response:)``
/// or ``RoutedSession/complete(elicitationId:)``), and then no end event
/// comes. Or the session ends it with no answer of the client: a cancel of the
/// run (`ToolContext.cancel(completionToken:)`), ``RoutedSession/cancelAll()``
/// or ``RoutedSession/close()``. Then the session sends this end, so that the
/// client can remove the question from its view.
public struct ElicitationEnd: Sendable, Equatable {
    /// The id of the question: the same ``ElicitationRequest/elicitationId``
    /// as in the ``SessionEvent/elicitationRequested(_:)`` of the question.
    public let elicitationId: ULID

    /// The response that the run got in place of an answer of the client.
    /// Its `action` is a cancel or a decline, never an accept, and its
    /// `reason` tells why the question ended. A question that the session
    /// ends now gets `.cancel(reason: RunPlane.runCancelledReason)`.
    public let response: ElicitationResponse

    /// Creates the end of a question.
    ///
    /// - Parameters:
    ///   - elicitationId: The id of the question.
    ///   - response: The response that the run got: a cancel or a decline.
    public init(elicitationId: ULID, response: ElicitationResponse) {
        self.elicitationId = elicitationId
        self.response = response
    }
}
