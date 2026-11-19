import Foundation
import FoundationModelsExtras

/// The default name of a root session with no title (D199 (b)), of a fork
/// with no title (D205), and the name of an imported session (D209 (h)):
/// ``RouterSessionDirectory`` gives it when it registers a new root session
/// or a new fork, when it reads a recorded root session, and when it imports
/// a session.
///
/// The rules are `SessionName.default(agentName:usedNames:)` and
/// `SessionName.fork(sourceName:usedNames:)` of FoundationModelsExtras. This
/// type only collects their inputs: the name of the agent from the facts of
/// the session, the name of the source of a fork, or the title of an import,
/// and the slugs of the other sessions in the same folder that are not
/// archived.
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

    /// The name of an imported session (D209 (h)), as the in-memory
    /// directory of FoundationModelsExtras gives it: `title` as given when
    /// its slug is empty or no used name has it, else the slug of `title`
    /// with the first free number (`SessionName.default(agentName:usedNames:)`).
    ///
    /// - Parameters:
    ///   - title: The title of the import request.
    ///   - folder: The working folder of the import.
    ///   - summaries: The summaries of the sessions that can hold a name, live
    ///     and recorded. Only those in `folder` that are not archived count.
    ///   - reserved: The slugs that other imports in `folder` hold and that
    ///     `summaries` may not show yet.
    /// - Returns: The name.
    static func makeImport(
        from title: String, in folder: URL, among summaries: [SessionSummary], reserved: Set<String>
    ) -> String {
        let usedNames = usedNames(besides: nil, in: folder, among: summaries).union(reserved)
        let slug = SessionSlug.make(from: title)
        guard !slug.isEmpty, usedNames.contains(slug) else { return title }
        return SessionName.default(agentName: title, usedNames: usedNames)
    }

    /// The slugs of the sessions of `summaries` in `folder` that are not
    /// archived, besides the session `id`.
    ///
    /// - Parameters:
    ///   - id: The session that the name is for, or `nil` for a session that
    ///     has no id yet.
    ///   - folder: The working folder of that session.
    ///   - summaries: The summaries of the sessions that can hold a name.
    /// - Returns: The used names.
    private static func usedNames(
        besides id: ULID?, in folder: URL, among summaries: [SessionSummary]
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
