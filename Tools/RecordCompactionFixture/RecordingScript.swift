import Foundation
import FoundationModels
import FoundationModelsRouter

/// Everything the recording is made FROM, in one place: the model, the
/// session settings, the two redaction settings, and the six scripted turns.
///
/// This type is the recipe that used to live as a table and a paragraph in
/// `Fixtures/CompactionRecording/README.md`. Each value here is what the
/// checked-in recording was made with, so `swift run RecordCompactionFixture`
/// reproduces the same conversation shape without anybody re-reading prose.
enum RecordingScript {
    /// The model that writes the recording: the same 30B model the gated
    /// real-model suites drive.
    ///
    /// This mirrors `RealModels.standard` in
    /// `Tests/FoundationModelsRouterIntegrationTests/Support/RealModels.swift`,
    /// which cannot be imported here because it lives inside a test target.
    /// A change there needs the same change here.
    static let recordingModel: ModelRef = "mlx-community/Muse-Glimmer-30B-4bit"

    /// The `.embedding` slot placeholder `Router.resolve` co-resides beside
    /// the generation model. The recording never calls it; the same small
    /// embedder the gated suites use keeps residency cheap.
    static let embeddingModel: ModelRef = "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"

    /// The working context the recording session runs at, mirroring
    /// `RealModels.context` for the reason ``recordingModel`` states.
    static let workingContextTokens = 8192

    /// The reply ceiling each turn runs under, in tokens.
    ///
    /// Sized for a REASONING model. The first recording attempt used 160 and
    /// produced six empty responses, because the 30B model spends its first
    /// tokens on reasoning; 900 leaves room for the reasoning and a real
    /// answer.
    static let replyTokenCeiling = 900

    /// Redaction setting 1 of 2: the session's working directory, set to a
    /// value chosen for the fixture.
    ///
    /// A session defaults its working directory to its own recording
    /// directory, which at record time is an absolute path on the recording
    /// machine, and the sidecar stores that path. Setting this synthetic
    /// value at record time is what keeps the machine path out of the bytes.
    ///
    /// Redaction setting 2 of 2 is an ABSENCE, so no constant can carry it:
    /// the `recordingRoot:` override stays unset where `main.swift` opens
    /// the session, because a per-session recording root is stamped into
    /// `session.json` as an absolute machine path (the `^pfdrppj` leak).
    static let fixtureWorkingDirectory = URL(
        fileURLWithPath: "/recordings/station-archive", isDirectory: true)

    /// The system instructions the recorded session runs under, byte for
    /// byte what the checked-in recording carries.
    static let instructions = """
        You are a terse, literal engineering assistant. Answer in one short paragraph. \
        You have two tools, `lookup-alpha` and `lookup-beta`. When the user asks you to \
        look up a step, call the matching tool with that step name and quote the \
        identifier it returns exactly.
        """

    /// The six scripted turns, byte for byte what the checked-in recording
    /// carries.
    ///
    /// The conversation is a synthetic engineering discussion — an
    /// ingest-path replacement for a "station archive" and its migration
    /// plan — written for this fixture. The two long turns put the folded
    /// span past the point where `Summarization.minimumSummaryTokens` stops
    /// binding; the short turns are the recency window; and the questions
    /// give the model reasons to call its tools.
    static let prompts = [
        """
        Design brief. We are replacing the ingest path for the station archive. The present path reads each
        station file end to end, parses every row into a record, and writes the whole batch to the index in one
        transaction, which means a single malformed row fails a file that is otherwise sound and leaves the
        index holding nothing from it. The replacement streams each file, parses row by row, and commits in
        bounded batches, so a malformed row costs its own batch and no more. Rows the parser rejects are
        written to a rejects file beside the index, with the source path, the row number, and the reason,
        rather than dropped. The rejects file is read by a person, not by a tool, because every rejection so
        far has needed somebody to decide whether the row was mistyped at the source or mistranscribed later,
        and no rule we have written separates those two. Batch size is a setting rather than a constant,
        because the right size differs by an order of magnitude between the small station files and the two
        large ones, and a single value that suits both does not exist. The index format itself does not
        change, so a reader built against the present path keeps working against the replacement without an
        edit. Summarize what you understand of the change in one short paragraph.
        """,
        """
        Migration plan. The two paths run side by side for one release. The new path writes to an index under a
        separate directory, the old path keeps writing where it always has, and a comparison job reads both and
        reports every station whose record counts, date ranges, or checksums differ. The comparison runs
        nightly and its report is kept, so a difference that appears once and goes away is still visible
        afterwards rather than lost. We cut over a station at a time rather than all at once, oldest station
        first, because the oldest files exercise the widest range of formats and a failure there is the one we
        most want to see early. A station is cut over only after seven consecutive clean comparison reports,
        and cutting over means the old path stops writing that station rather than that its old index is
        removed; the old index stays until the release after, so a rollback is a configuration change and not a
        restore. The comparison job is the piece with no fallback: if it cannot read either index it reports a
        failure rather than an empty difference, because an empty difference and an unread index look identical
        on the report and only one of them means the two paths agree. Cut-over for every station is authorised
        by the Kestrel board and by nobody else, and the comparison job refuses to run for a station the
        Kestrel board has not approved. Restate the cut-over rule in one short paragraph.
        """,
        "Look up step ONE with your tools and tell me the identifier it returns.",
        "Name the file rejected rows are written to.",
        "State how many clean comparison reports a station needs before cut-over.",
        "State what a rollback costs after cut-over.",
    ]

    /// The two tools the recorded session mounts.
    static var tools: [any FoundationModels.Tool] {
        [LookupTool(name: "lookup-alpha"), LookupTool(name: "lookup-beta")]
    }
}
