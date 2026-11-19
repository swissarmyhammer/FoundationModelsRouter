import Foundation
import FoundationModels
import FoundationModelsExtras

/// A failure of ``RoutedModel/recordSession(from:configuration:)``.
///
/// A write that throws leaves no session folder: not the folder of the
/// session, and not its temporary folder.
public enum SessionRecordingWriteError: Error, Equatable, LocalizedError {
    /// The handle records no durable session: its router has no recordings
    /// root, or its recording level is ``RecordingLevel/off``. A session that
    /// the handle makes writes no `index.md` and no `transcript.jsonl` either.
    case noDurableRecording

    /// The recorder did not put each event of the transcript into the
    /// `transcript.jsonl` of the session. The recorder logs and drops an
    /// event that it cannot write (``TranscriptRecorder``), so the write reads
    /// the file back and counts the events.
    ///
    /// - Parameters:
    ///   - expected: The number of events that the write gave the recorder.
    ///   - written: The number of events that the file holds.
    case eventsNotWritten(expected: Int, written: Int)

    /// A localized message describing what error occurred.
    public var errorDescription: String? {
        switch self {
        case .noDurableRecording:
            return "The model handle records no durable session, so it cannot write a session recording."
        case .eventsNotWritten(let expected, let written):
            return "The recorder wrote \(written) of the \(expected) events of the session recording."
        }
    }
}

extension RoutedModel where Container == any LoadedLLMContainer {
    /// Writes a new session recording from `transcript`, with no live session
    /// (D209 (h)), and returns the id of the new session.
    ///
    /// A host uses it to continue a history that it did not make with this
    /// router, for example an imported session of another agent. The host
    /// then opens the session with the normal restore,
    /// ``restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:isNoOpToolCall:userPresence:hookSessionKey:claimingRuns:transcriptReader:switchingModel:)``,
    /// with the same `recordingRoot` as `configuration`. The restore reads the
    /// recording with no special case, because the write makes what a live
    /// root session makes:
    ///
    /// - A new id, and the folder `<recording root>/<id>/`. The recording
    ///   root is the one ``makeSession(configuration:)`` gives a session with
    ///   this configuration.
    /// - `index.md` with the ``SessionRecord`` of a new root session of this
    ///   handle: the working folder (`configuration.workingDirectory`, else
    ///   the session folder), the first facts of `configuration` (the agent,
    ///   the title and the origin among them), the slot, the model and the
    ///   context of this handle, the resolved profile of its run, the
    ///   configuration envelope and the current schema version.
    /// - `transcript.jsonl` with the `session` event, then one event for each
    ///   entry of `transcript`, in order. The events go through the recorder
    ///   of this handle and the entry mapper of a live session, so the
    ///   recording level and the redaction of the router apply to them.
    ///
    /// The configuration envelope holds the compaction budget of
    /// `configuration`, so the restore gives the session that budget. The
    /// last `.response` event carries the size of `transcript` as the counter
    /// of this model counts it, as the usage of a live submission. Thus the
    /// restored session knows how full its context is, and a transcript over
    /// the trigger of the budget compacts at the first answer by the normal
    /// rule. A transcript with no `.response` entry has no measured size.
    ///
    /// When `transcript` holds a prompt, the record takes the instant of the
    /// write as its first activity (``SessionRecord/firstActivityAt``), so
    /// a listing for a client shows the session.
    ///
    /// The write is atomic for the folder. It writes into a temporary folder
    /// beside the session folder, in the same recording root, and renames it
    /// to the session folder at the end. A write that throws removes the
    /// temporary folder and leaves no session folder.
    ///
    /// The write registers no session in the session directory and starts
    /// no hook: no session is live.
    ///
    /// - Parameters:
    ///   - transcript: The history of the session, in order: the instructions
    ///     entry when there is one, the prompts, the responses and the tool
    ///     entries. The leading instructions entry is what the restored model
    ///     reads; give the text of `configuration.instructions` there.
    ///   - configuration: The configuration of the session, as
    ///     ``makeSession(configuration:)`` takes it. The write reads the
    ///     values that a record holds: the instructions, the working folder,
    ///     the recording root, the tool names, the compaction settings, the
    ///     spawn, the grammar, the other recorded settings and the first
    ///     facts. It does not read the values that a live session only holds,
    ///     for example the parent call and the hook key.
    /// - Returns: The id of the new session.
    /// - Throws: ``SessionRecordingWriteError/noDurableRecording`` when this
    ///   handle records no durable session;
    ///   ``SessionRecordingWriteError/eventsNotWritten(expected:written:)``
    ///   when the recorder dropped an event; the error of the token counter of
    ///   this model; or the error of a folder or a file operation.
    public func recordSession(from transcript: Transcript, configuration: SessionConfiguration) async throws -> ULID {
        guard let indexWriter = durableRecording?.indexWriter, indexWriter.writes else {
            throw SessionRecordingWriteError.noDurableRecording
        }
        let id = ULID.generate()
        let folder = recordingDirectory(forSessionId: id, recordingRoot: configuration.recordingRoot)
        let record = newRootRecord(
            id: id, folder: folder, transcript: transcript, configuration: configuration, indexWriter: indexWriter)
        let events = try recordedEvents(of: transcript, sessionId: id, agentSpawn: configuration.agentSpawn)
        try await writeAtomically(record, events: events, into: folder)
        return id
    }

    /// The ``SessionRecord`` of a new root session of this handle, as
    /// `RoutedSessionActor` makes it for a vended root.
    ///
    /// - Parameters:
    ///   - id: The id of the session.
    ///   - folder: The session folder.
    ///   - transcript: The history of the session.
    ///   - configuration: The configuration of the session.
    ///   - indexWriter: The index writer of this handle.
    /// - Returns: The record.
    private func newRootRecord(
        id: ULID, folder: URL, transcript: Transcript, configuration: SessionConfiguration,
        indexWriter: SessionIndexWriter
    ) -> SessionRecord {
        let workingDirectory = configuration.workingDirectory ?? folder
        var recorded = configuration
        recorded.workingDirectory = workingDirectory
        var record = SessionRecord(
            sessionId: id,
            workingDirectory: workingDirectory,
            updatedAt: Date(),
            slot: slot,
            model: chosen,
            context: resolution.contextTokens,
            recordingLevel: indexWriter.recordingLevel,
            routerId: routerId,
            facts: configuration.initialFacts,
            instructions: configuration.instructions,
            grammar: configuration.grammar?.source,
            profile: indexWriter.profile,
            agentSpawn: configuration.agentSpawn,
            configuration: recorded.persistable)
        if transcript.contains(where: Self.isPrompt) {
            record.recordActivity(at: record.updatedAt)
        }
        return record
    }

    /// Whether `entry` is a prompt.
    ///
    /// - Parameter entry: The entry.
    /// - Returns: `true` for a `.prompt` entry.
    private static func isPrompt(_ entry: Transcript.Entry) -> Bool {
        guard case .prompt = entry else { return false }
        return true
    }

    /// The events of the `transcript.jsonl` of a new root session with the
    /// history `transcript`: the `session` event, then one event for each
    /// entry, mapped as a live session maps it
    /// (``TranscriptDiffer/partials(baseline:current:divergence:routerId:sessionId:parentId:slot:model:)``).
    /// The last `.response` event carries the size of `transcript` as its
    /// usage.
    ///
    /// - Parameters:
    ///   - transcript: The history of the session.
    ///   - sessionId: The id of the session.
    ///   - agentSpawn: The spawn of the session, or `nil`.
    /// - Returns: The events, in order, with no `seq` and no `ts`.
    /// - Throws: The error of the token counter of this model.
    private func recordedEvents(
        of transcript: Transcript, sessionId: ULID, agentSpawn: SessionRecord.AgentSpawn?
    ) throws -> [TranscriptEvent.Partial] {
        let meta = TranscriptEvent.Partial(
            routerId: routerId, sessionId: sessionId, slot: slot, model: chosen, kind: .session,
            agentSpawn: agentSpawn)
        var entries = TranscriptDiffer.partials(
            baseline: TranscriptDiffer.Baseline(transcript: Transcript()), current: transcript, divergence: nil,
            routerId: routerId, sessionId: sessionId, parentId: nil, slot: slot, model: chosen)
        if let lastResponse = entries.lastIndex(where: { $0.kind == .response }) {
            let size = try container.tokenCounter.count(transcript)
            entries[lastResponse] = entries[lastResponse].stampingUsage(tokensIn: size, tokensOut: 0)
        }
        return [meta] + entries
    }

    /// Writes `record` and `events` into a temporary folder beside `folder`,
    /// checks that the transcript file holds each event, and renames the
    /// temporary folder to `folder`. A step that throws removes the temporary
    /// folder.
    ///
    /// - Parameters:
    ///   - record: The record of the session.
    ///   - events: The events of the transcript, in order.
    ///   - folder: The session folder. It must not exist.
    /// - Throws: ``SessionRecordingWriteError/eventsNotWritten(expected:written:)``
    ///   when the recorder dropped an event, or the error of a folder or a
    ///   file operation.
    private func writeAtomically(_ record: SessionRecord, events: [TranscriptEvent.Partial], into folder: URL)
        async throws
    {
        let temporary = Self.temporaryFolder(of: folder)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        do {
            try SessionIndexFile.save(record, in: temporary)
            for event in events {
                await recorder.append(event, to: temporary)
            }
            let written = try JSONLFile(url: temporary.appendingPathComponent(transcriptFileName, isDirectory: false))
                .records(as: TranscriptEvent.self).count
            guard written == events.count else {
                throw SessionRecordingWriteError.eventsNotWritten(expected: events.count, written: written)
            }
            try FileManager.default.moveItem(at: temporary, to: folder)
        } catch {
            Self.removeTemporaryFolder(temporary)
            throw error
        }
    }

    /// The temporary folder of the write of the session folder `folder`: a
    /// hidden folder beside it, in the same recording root, so that the
    /// rename at the end of the write stays on one volume. A reader of a
    /// recording root skips a hidden folder (``TranscriptFileDiscovery``), so
    /// a write in progress, and a temporary folder that a stopped process
    /// left, is no session of the root.
    ///
    /// - Parameter folder: The session folder.
    /// - Returns: The temporary folder.
    static func temporaryFolder(of folder: URL) -> URL {
        folder.deletingLastPathComponent()
            .appendingPathComponent(".\(folder.lastPathComponent).writing", isDirectory: true)
    }

    /// Removes the temporary folder of a write that failed, and logs a
    /// removal that fails: the folder then stays in the recording root.
    ///
    /// - Parameter temporary: The temporary folder.
    private static func removeTemporaryFolder(_ temporary: URL) {
        do {
            try FileManager.default.removeItem(at: temporary)
        } catch {
            RouterTelemetry.makeLogger(.recording).error(
                "a failed session recording write cannot remove its temporary folder",
                metadata: RouterTelemetry.errorMetadata(error).merging([
                    RouterTelemetry.LogMetadataKey.filePath: "\(temporary.path)"
                ]) { _, new in new })
        }
    }
}
