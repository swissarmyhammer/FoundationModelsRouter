import Foundation
import FoundationModelsExtras

/// The default name of a root session with no title (D199 (b)):
/// ``RouterSessionDirectory`` gives it when it registers a new root session,
/// and when it reads a recorded root session.
///
/// The rule is `SessionName.default(agentName:usedNames:)` of
/// FoundationModelsExtras. This type only collects its two inputs: the name
/// of the agent from the facts of the session, and the slugs of the other
/// sessions in the same folder that are not archived.
enum SessionDefaultTitle {
    /// Tells whether a session needs a default name: its facts hold no
    /// title, or an empty title, which a summary reads as no title.
    ///
    /// - Parameter facts: The facts of a session.
    /// - Returns: `true` when the session has no title.
    static func isMissing(in facts: SessionFacts) -> Bool {
        given(facts.title) == nil
    }

    /// A title as a session holds it: an empty title counts as no title.
    /// The facts of a new session, a live summary and a recorded summary
    /// read a title through this call, thus they agree on an empty title.
    ///
    /// - Parameter title: A title, or `nil`.
    /// - Returns: `title`, or `nil` when `title` is `nil` or empty.
    static func given(_ title: String?) -> String? {
        title.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The default name of the session `id`.
    ///
    /// - Parameters:
    ///   - facts: The facts of the session. The agent name comes from them:
    ///     the agent name, else the agent id. A session with neither gets the
    ///     fallback name of `SessionName`.
    ///   - id: The session id. Its own summary in `summaries` does not count.
    ///   - folder: The working folder of the session.
    ///   - summaries: The summaries of the sessions that can hold a name, live
    ///     and recorded. Only those in `folder` that are not archived count.
    /// - Returns: The default name. It is a slug, and it is never empty.
    static func make(
        for facts: SessionFacts, of id: ULID, in folder: URL, among summaries: [SessionSummary]
    ) -> String {
        let path = RouterSessionDirectory.comparablePath(of: folder)
        let usedNames = summaries.lazy
            .filter { $0.id != id && $0.state != .archived }
            .filter { RouterSessionDirectory.comparablePath(of: $0.workingDirectory) == path }
            .map(\.slug)
        return SessionName.default(agentName: agentName(in: facts), usedNames: Set(usedNames))
    }

    /// The name of the agent of a session: the agent name, else the agent
    /// id, else empty. An empty name or id counts as none.
    ///
    /// - Parameter facts: The facts of the session.
    /// - Returns: The name of the agent.
    private static func agentName(in facts: SessionFacts) -> String {
        [facts.agentName, facts.agentID].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }
}
