import Foundation
import FoundationModelsExtras

/// The default name of a root session with no title (D199 (b)), and of a
/// fork with no title (D205): ``RouterSessionDirectory`` gives it when it
/// registers a new root session or a new fork, and when it reads a recorded
/// root session.
///
/// The rules are `SessionName.default(agentName:usedNames:)` and
/// `SessionName.fork(sourceName:usedNames:)` of FoundationModelsExtras. This
/// type only collects their inputs: the name of the agent from the facts of
/// the session, or the name of the source of a fork, and the slugs of the
/// other sessions in the same folder that are not archived.
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
        SessionName.default(
            agentName: agentName(in: facts), usedNames: usedNames(besides: id, in: folder, among: summaries))
    }

    /// The default name of the fork `id` of the session `sourceID` (D205):
    /// `SessionName.fork(sourceName:usedNames:)` of FoundationModelsExtras,
    /// from the slug of the source, among the same used names as
    /// ``make(for:of:in:among:)``.
    ///
    /// - Parameters:
    ///   - sourceID: The id of the source. Its summary in `summaries` gives
    ///     its name. A source with no summary there gives the fallback name
    ///     of `SessionName`.
    ///   - id: The id of the fork. Its own summary in `summaries` does not
    ///     count.
    ///   - folder: The working folder of the fork.
    ///   - summaries: The summaries of the sessions that can hold a name, live
    ///     and recorded.
    /// - Returns: The fork name. It is a slug, and it is never empty.
    static func makeFork(
        of sourceID: ULID, for id: ULID, in folder: URL, among summaries: [SessionSummary]
    ) -> String {
        SessionName.fork(
            sourceName: summaries.first { $0.id == sourceID }?.slug ?? "",
            usedNames: usedNames(besides: id, in: folder, among: summaries))
    }

    /// The slugs of the sessions of `summaries` in `folder` that are not
    /// archived, besides the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session that the name is for.
    ///   - folder: The working folder of that session.
    ///   - summaries: The summaries of the sessions that can hold a name.
    /// - Returns: The used names.
    private static func usedNames(
        besides id: ULID, in folder: URL, among summaries: [SessionSummary]
    ) -> Set<String> {
        let path = RouterSessionDirectory.comparablePath(of: folder)
        return Set(
            summaries.lazy
                .filter { $0.id != id && $0.state != .archived }
                .filter { RouterSessionDirectory.comparablePath(of: $0.workingDirectory) == path }
                .map(\.slug))
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
