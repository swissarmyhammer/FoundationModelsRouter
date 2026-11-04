import Foundation
import FoundationModels
import FoundationModelsExtras

/// One session restored from disk, with what the restore could not re-apply.
///
/// ``RoutedModel/restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)`` returns
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
        /// The restored session whose ``SessionRecord/context`` differs.
        public let session: ULID

        /// The working context, in tokens, the session was recorded at.
        public let recorded: Int

        /// The working context, in tokens, the restoring profile resolved.
        public let resolved: Int
    }

    /// The restored session, named by the id the caller resumed.
    public let session: any RoutedSession

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
    /// true. The supplied string reaches the session actor and the transcript
    /// the model itself reads. See
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
    ///   - recorded: The instructions the session's `index.md` recorded, or `nil`. A `nil`
    ///     reads as a length of zero.
    ///   - supplied: The instructions the restoring caller supplied.
    /// - Returns: The event's body text.
    static func instructionsDivergenceText(recorded: String?, supplied: String) -> String {
        """
        \(instructionsDivergencePhrase): recorded \(recorded?.count ?? 0) characters, \
        supplied \(supplied.count) characters
        """
    }

    /// The body of the ``TranscriptEvent/Kind/modelChanged`` event a restore
    /// appends when it moves a session onto another model or slot.
    ///
    /// The text names the old slot and model, and then the new slot and
    /// model. The event itself is stamped with the new ones.
    ///
    /// - Parameters:
    ///   - old: The slot and the model the session was recorded on.
    ///   - new: The slot and the model the session is restored onto.
    /// - Returns: The event's body text.
    static func modelChangedText(
        from old: (slot: ModelSlot, model: ModelRef), to new: (slot: ModelSlot, model: ModelRef)
    ) -> String {
        "model changed from \(old.slot.rawValue) \(old.model.stringValue) to \(new.slot.rawValue) \(new.model.stringValue)"
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Restores one recorded root session from disk, by its id.
    ///
    /// This is the resume surface. The session keeps its own id, its parent
    /// id, and its recording directory, so the next submission appends to the
    /// transcript already on disk. Its model and slot resolve from its
    /// ``SessionRecord`` against this call's owning profile, and a mismatch
    /// is a typed error. With `switchingModel`, the session restores onto
    /// this handle instead, and it keeps its id. See
    /// ``restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)`` for what
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
    ///     submission. A supplied string equal to the recorded one changes nothing
    ///     and writes nothing. A supplied string that differs appends one
    ///     ``TranscriptEvent/Kind/divergence`` event to the session's
    ///     transcript. A later reader of that file then learns the session
    ///     ran on instructions the file does not hold. The recorded
    ///     `.instructions` entry on disk is never rewritten.
    ///   - tools: The tools the restored session's model can call. Every
    ///     recorded tool name with no supplied instance is reported in
    ///     ``RestoredSession/configurationReport``.
    ///   - toolOutputProtection: The host rule whose protected tool outputs
    ///     every compaction on the restored session keeps word for word, or `nil`
    ///     (the default) to protect nothing. The recording does not hold the
    ///     rule, because it is a closure, so a host gives it again here, as
    ///     it gives the tools. See ``ToolOutputProtection``.
    ///   - isNoOpToolCall: The host check that marks a tool call of the
    ///     restored session as a no-op, or
    ///     ``SessionConfiguration/defaultIsNoOpToolCall`` (the default) to
    ///     mark no call. The recording does not hold the check, because it
    ///     is a closure, so a host gives it again here, as it gives the
    ///     tools. See ``SessionConfiguration/isNoOpToolCall``.
    ///   - userPresence: The user presence of the restored session, or `nil`
    ///     (the default) to keep the recorded value. A record with no
    ///     recorded value restores ``UserPresence/interactive``. The user
    ///     presence belongs to the current client, not to the recording. A
    ///     host that resumes an interactive session with no user gives
    ///     ``UserPresence/headless`` here, and the reverse. The supplied value
    ///     also replaces the recorded value on each recorded fork. The
    ///     session's `index.md` on disk does not change. See
    ///     ``SessionConfiguration/userPresence``.
    ///   - hookSessionKey: The key of the hook lineage of the restored
    ///     session, or `nil` (the default) to give it its own id as its key,
    ///     the same key as before the restore. A host sets it when the
    ///     restored session joins the lineage of other sessions, for example
    ///     a key shared by the sessions of one working directory. The
    ///     recording does not hold the key, because it is for the hooks only,
    ///     so a host gives it again here. A recorded fork in the working
    ///     directory of the session gets the key too, and so does a sub-agent
    ///     that starts from the session while it is open. See
    ///     ``SessionConfiguration/hookSessionKey``.
    ///   - claimingRuns: The orphan runs that the host takes, or empty (the
    ///     default) to take none. The restore posts no `.lost` terminal for
    ///     a claimed run, and the session keeps the claim open until the host
    ///     completes the run
    ///     (``RoutedSession/completeClaimedRun(_:outcome:detail:)``) or the
    ///     session closes. See
    ///     ``RoutedModel/restoreSessionTree(root:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``.
    ///   - transcriptReader: The reader of the recorded transcripts of
    ///     sessions, or `nil` (the default) for no reader. The recording does
    ///     not hold the reader, because it is a live object, so a host gives
    ///     it again here, as it gives the tools. See
    ///     ``SessionConfiguration/transcriptReader``.
    ///   - switchingModel: `false` (the default) to restore the session onto
    ///     the model of its recorded slot, which must be the model it was
    ///     recorded on. `true` to restore the session onto THIS handle, also
    ///     when its recorded model or slot is another one. This is how a host
    ///     moves a session to another model and keeps its id.
    ///
    ///     The host first suspends the old session
    ///     (``RoutedSession/suspend()``). Two live sessions with one id would
    ///     share one folder, and Router does not check this. The restore then
    ///     keeps the id, the session folder and the lineage. It does not end
    ///     the old session: a suspended session has no ended marker. A
    ///     restore in the same process, also while the host still holds the
    ///     old session object, replaces the old session in the session
    ///     directory of the router.
    ///
    ///     Each moved session appends one
    ///     ``TranscriptEvent/Kind/modelChanged`` event to its transcript, and
    ///     its `index.md` takes the new ``SessionRecord/slot``, the new
    ///     ``SessionRecord/model`` and the new ``SessionRecord/context``. The
    ///     events of the old model stay as they are, so a read of the
    ///     transcript by the id returns the whole history. The next
    ///     submission runs on the new model and records its `model.ref`. A
    ///     session that is on this slot and this model already changes
    ///     nothing and writes no event.
    ///
    ///     The recorded forks under the session move with it, to this same
    ///     handle, because a fork is a part of the same conversation. A fork
    ///     that stayed on the old model would fail with
    ///     ``SessionTreeRestorationError/modelMismatch(session:slot:recorded:resident:)``.
    ///     The restore releases the forks anyway.
    ///
    ///     The history can be larger than the context of the new model. The
    ///     restore calls no compaction. It re-applies the recorded
    ///     compaction budget as it is: the limit of the budget is in tokens
    ///     and is not scaled to the new context. A context that differs from
    ///     the recorded one is reported in
    ///     ``RestoredSession/contextMismatches``. A host that moves a session
    ///     to a smaller context compacts it with
    ///     ``RoutedSession/compact()`` before the next submission.
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
        tools: [any Tool] = [],
        toolOutputProtection: ToolOutputProtection? = nil,
        isNoOpToolCall: @escaping NoOpToolCallCheck = SessionConfiguration.defaultIsNoOpToolCall,
        userPresence: UserPresence? = nil,
        hookSessionKey: String? = nil,
        claimingRuns: Set<RunKey> = [],
        transcriptReader: (any SessionTranscriptReader)? = nil,
        switchingModel: Bool = false
    ) async throws -> RestoredSession {
        let tree = try await restoreSessionTree(
            root: id, recordingRoot: recordingRoot, instructions: instructions, tools: tools,
            toolOutputProtection: toolOutputProtection, isNoOpToolCall: isNoOpToolCall,
            userPresence: userPresence, hookSessionKey: hookSessionKey, claimingRuns: claimingRuns,
            transcriptReader: transcriptReader, switchingModel: switchingModel)
        return RestoredSession(
            session: tree.root,
            configurationReport: tree.configurationReport,
            contextMismatches: tree.contextMismatches
        )
    }

    /// The working directory one recorded session was vended with, read from
    /// its ``SessionRecord`` without restoring it.
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
        return node.record.workingDirectory
    }
}
