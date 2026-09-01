import Foundation
import FoundationModels

/// One session restored from disk, with what the restore could not re-apply.
///
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:)`` returns
/// this value. It names one session, never that session's recorded forks: a
/// caller resumes a session by an id it holds, and it holds no id for a fork.
///
/// The restore still rebuilds the recorded forks under ``session``, so a row
/// in ``configurationReport`` or in ``contextMismatches`` can name one of
/// them. Read a row's own `session` id to tell which session it describes.
public struct RestoredSession: Sendable {
    /// One restored session whose recorded working context differs from the
    /// context the restoring profile resolved. The session runs against
    /// ``ContextMismatch/resolved``. This is a warning, not an error, because
    /// the same model can resolve a different context on a different machine.
    public struct ContextMismatch: Sendable, Equatable {
        /// The restored session whose ``SessionSidecar/context`` differs.
        public let session: ULID

        /// The working context, in tokens, the session was recorded at.
        public let recorded: Int

        /// The working context, in tokens, the restoring profile resolved.
        public let resolved: Int
    }

    /// The restored session, named by the id the caller resumed.
    public let session: RoutedSession

    /// What the restore could not re-apply from the recorded configuration
    /// envelopes.
    public let configurationReport: SessionConfigurationRestorationReport

    /// Every restored session whose recorded working context differs from the
    /// live resolution, in walk order, or empty.
    public let contextMismatches: [ContextMismatch]
}

extension RestoredSession {
    /// The stable phrase the instructions-divergence event opens with.
    ///
    /// A person greps a repository of committed transcripts for this exact
    /// text to find every session that ran on instructions the record does
    /// not hold.
    ///
    /// The phrase names the whole restored session, and every word of it is
    /// true. The supplied string reaches the session actor, the sidecar of
    /// any later fork, and the transcript the model itself reads. See
    /// ``TranscriptDiffer/replacingLeadingInstructions(of:with:)``.
    ///
    /// This constant is public because the grep target is a contract. A
    /// consumer in another package pins this symbol in a test, so a refactor
    /// that edits the phrase fails a build. A consumer cannot pin a contract
    /// it cannot name. Without this symbol, every saved grep finds nothing,
    /// and the record then looks empty rather than broken.
    public static let instructionsDivergencePhrase =
        "restored session instructions differ from the recorded instructions"

    /// The body of the ``TranscriptEvent/Kind/divergence`` event a restore
    /// appends when supplied instructions differ from the recorded ones.
    ///
    /// The text names both lengths in characters and carries neither
    /// instructions body. A length is enough to show that the two strings are
    /// not the same, and it leaks no content into a committed file. A hash
    /// would say no more, because a reader cannot resolve a hash back to a
    /// string either.
    ///
    /// - Parameters:
    ///   - recorded: The instructions the sidecar recorded, or `nil`. A `nil`
    ///     reads as a length of zero.
    ///   - supplied: The instructions the restoring caller supplied.
    /// - Returns: The event's body text.
    static func instructionsDivergenceText(recorded: String?, supplied: String) -> String {
        """
        \(instructionsDivergencePhrase): recorded \(recorded?.count ?? 0) characters, \
        supplied \(supplied.count) characters
        """
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Restores one recorded root session from disk, by its id.
    ///
    /// This is the resume surface. The session keeps its own id, its parent
    /// id, and its recording directory, so the next turn appends to the
    /// transcript already on disk. Its model and slot resolve from its
    /// ``SessionSidecar`` against this call's owning profile, and a mismatch
    /// is a typed error. See
    /// ``restoreSessionTree(root:recordingRoot:instructions:tools:)`` for what
    /// the restore re-applies and what it does not.
    ///
    /// The recorded forks under the named session are rebuilt too, and are
    /// then released. Nothing in the returned value names one.
    ///
    /// - Precondition: The owning ``LanguageModelProfile`` is still alive.
    ///
    /// - Parameters:
    ///   - id: The recorded root session's span id.
    ///   - recordingRoot: The exact directory to load from, or `nil` for the
    ///     nested `<recordingsRoot>/<routerId>/` layout. Pass the same root
    ///     the session was vended with.
    ///   - instructions: Instructions that replace the recorded ones, or `nil`
    ///     (the default) to keep the recorded string. A supplied string
    ///     replaces the recorded one on the restored session. It also replaces
    ///     the leading `.instructions` entry of the transcript the restored
    ///     model reads. So the model obeys the supplied string from its next
    ///     turn. A supplied string equal to the recorded one changes nothing
    ///     and writes nothing. A supplied string that differs appends one
    ///     ``TranscriptEvent/Kind/divergence`` event to the session's
    ///     transcript. A later reader of that file then learns the session
    ///     ran on instructions the file does not hold. The recorded
    ///     `.instructions` entry on disk is never rewritten.
    ///   - tools: The tools the restored session's model can call. Every
    ///     recorded tool name with no supplied instance is reported in
    ///     ``RestoredSession/configurationReport``.
    /// - Returns: The restored session and the two restore reports.
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` when the
    ///   recording root holds no session with this id;
    ///   ``SessionTreeRestorationError`` for a restoration-specific failure;
    ///   ``TranscriptTreeError`` or ``TranscriptReconstructionError`` for what
    ///   the tree load and the transcript read throw.
    public func restoreSession(
        id: ULID,
        recordingRoot: URL? = nil,
        instructions: String? = nil,
        tools: [any Tool] = []
    ) async throws -> RestoredSession {
        let tree = try await restoreSessionTree(
            root: id, recordingRoot: recordingRoot, instructions: instructions, tools: tools)
        return RestoredSession(
            session: tree.root,
            configurationReport: tree.configurationReport,
            contextMismatches: tree.contextMismatches
        )
    }

    /// The working directory one recorded session was vended with, read from
    /// its ``SessionSidecar`` without restoring it.
    ///
    /// A host that resumes a session in a working directory of its own must
    /// be able to compare that directory with the recorded one and refuse
    /// before it builds anything. This read loads the transcript tree and
    /// nothing else: no backend, no live session, and no write.
    ///
    /// - Parameters:
    ///   - id: The recorded session's span id.
    ///   - recordingRoot: The exact directory to load from, or `nil` for the
    ///     nested `<recordingsRoot>/<routerId>/` layout.
    /// - Returns: The recorded working directory.
    /// - Throws: ``TranscriptTreeError/sessionNotFound(_:)`` when the
    ///   recording root holds no session with this id;
    ///   ``SessionTreeRestorationError/noDurableRecordingsRoot`` when
    ///   `recordingRoot` is `nil` and this handle has no durable root;
    ///   ``TranscriptTreeError`` for what ``TranscriptTree/load(under:)``
    ///   throws.
    public func recordedWorkingDirectory(
        ofSession id: ULID, recordingRoot: URL? = nil
    ) throws -> URL {
        let tree = try transcriptTree(recordingRoot: recordingRoot)
        guard let node = tree.session(id) else {
            throw TranscriptTreeError.sessionNotFound(id)
        }
        return node.sidecar.workingDirectory
    }
}
