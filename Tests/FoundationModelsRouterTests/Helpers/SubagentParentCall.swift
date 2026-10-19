import FoundationModelsExtras

@testable import FoundationModelsRouter

extension ToolContext {
    /// The context of a `start agent` call of `parent`: the parent call
    /// (``SessionConfiguration/parentCall``) of a sub-agent that `parent`
    /// starts.
    ///
    /// The hook suites make a sub-agent session with it, so that the session
    /// gets the hook lineage of a sub-agent of `parent`.
    ///
    /// - Parameter parent: The session that starts the sub-agent.
    /// - Returns: The context of the call.
    static func startAgentCall(of parent: any RoutedSession) -> ToolContext {
        ToolContext(
            sessionID: parent.id, runPlane: RunPlane(), sink: DroppingEventSink(), tool: "agents",
            op: "start agent", completionToken: ToolContext.makeCompletionToken(), isCancelled: { false })
    }
}
