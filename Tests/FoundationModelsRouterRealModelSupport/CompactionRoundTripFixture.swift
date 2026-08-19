import FoundationModelsRouter

/// The scripted fixture ``CompactionRoundTripIntegrationTests`` drives and
/// `ScriptedTurnSizingTests` bounds: the working context, the reply ceiling,
/// the system instructions, the fold budget, and the scripted turns.
///
/// One type carries all five because they are one measurement, not five
/// settings: the turns are sized against the context's 0.80 trigger, the
/// sizing suite multiplies the reply ceiling into its worst case, and the
/// fold budget decides which pipeline stage the live run must reach. The
/// gated suite lives in the real-model integration target and the sizing
/// suite lives in the hermetic unit target, so the fixture lives here, in
/// the plain support target both of them read (task ^cvsh3m9) — a change to
/// any value reaches both suites at once, and the sizing suite goes red on
/// every plain `swift test` before a 20-minute gated run can.
public enum CompactionRoundTripFixture {
    /// The working context the round trip resolves the tiny model at —
    /// smaller than ``RealModels/context`` so scripted turns cross the 0.80
    /// compaction trigger without needing huge prompts.
    public static let context = 2048

    /// The reply ceiling every scripted turn below is submitted with, and the
    /// worst case `ScriptedTurnSizingTests` bounds a turn's total size by.
    ///
    /// Deliberately local, and deliberately not
    /// `GatedRealModelBudget.responseTokenCeiling` — the shared ceiling every
    /// other gated turn in this package now uses. This constant is a fixture
    /// dimension, not only a limit on one reply:
    /// `ScriptedTurnSizingTests/triggerIsNotReachedBeforeAnOldSpanExists()`
    /// multiplies it by `TurnTruncation`'s `keepRecentTurns` (4) to get the
    /// largest size the first turns can reach, then compares that size against
    /// the 1638-token trigger of ``context`` (2048). The shared ceiling of 4096
    /// makes that product 16384, far above the trigger, and that **ungated**
    /// sizing test fails. Raise this value only together with the fixture it
    /// sizes.
    ///
    /// The turns of the gated loop assert nothing about their own replies, so
    /// a reply this ceiling truncates costs the round trip nothing. The two
    /// turns that do read a reply — the post-compaction recall and the turn on
    /// the restored session — carry the shared ceiling instead.
    public static let replyMaxTokens = 64

    /// The system instructions the round trip's session is created with —
    /// part of the transcript's header, which no compaction stage may touch,
    /// so `ScriptedTurnSizingTests` counts it too.
    public static let instructions =
        "You are a terse assistant. Follow each instruction exactly and keep replies to one sentence."

    /// The budget the round trip folds against.
    ///
    /// Deliberately not the default (`target` 0.50). A 0.50 target of this
    /// fixture's 2048-token working context is 1024 estimated tokens, and the
    /// four newest scripted turns — the recency window
    /// ``ToolOutputElision``/``TurnTruncation`` may not touch — estimate
    /// within a couple of hundred tokens of that either side depending on how
    /// long the model's own four most recent replies happened to run. Whether
    /// the deterministic stages landed under target on their own, and so
    /// whether ``Summarization`` ran at all, was therefore decided by sampled
    /// reply lengths rather than by anything the gated suite asserts — the same
    /// run could reach stage 3 or stop at stage 2 (task f80n046). Both shapes now
    /// record a compaction checkpoint (task ^h1008kb), but only the stage-3
    /// run synthesizes the real summary whose recall step 3 measures.
    ///
    /// A 0.25 target is 512 tokens, which the recency window's own prompt text
    /// exceeds on its own by a wide margin whichever four turns it happens to
    /// be — `ScriptedTurnSizingTests/recencyWindowCannotFitUnderTheFoldTarget()`
    /// pins that mechanically — so the deterministic stages cannot land under
    /// it and the model-assisted stage always runs. It changes nothing about
    /// *what* is folded: the old/recent split is `keepRecentTurns`' business,
    /// not the target's, so the folded span, the summary, and the restored
    /// window are exactly what a default-budget fold would produce on the run
    /// where it happened to reach stage 3.
    public static let foldBudget = TokenBudget(limit: context, target: foldTargetShare)

    /// The share of ``context`` the fold must come down to — the `target` of
    /// ``foldBudget``, named here so the doc comment above has one value to
    /// reason about. See that comment for why 0.25 rather than the 0.50
    /// default.
    private static let foldTargetShare = 0.25

    /// Long, distinct scripted documents fed into the session one per turn —
    /// enough cumulative text, against ``context``'s small 2048-token budget,
    /// to cross the 0.80 compaction trigger within a handful of turns. The
    /// first plants a fact only recoverable, after compaction, from the
    /// fold's summary — mirroring `Examples/CompactionDemo`'s own fixtures.
    ///
    /// Each turn is a long paragraph, and the length is load-bearing rather
    /// than decorative: crossing the trigger takes 1638 measured tokens
    /// (`0.80 * 2048`), so the turns have to carry that much text between them
    /// before the gated loop runs out of them. The shorter versions these
    /// replaced totalled roughly 718 estimated tokens across all eight — the
    /// live run measured 846 and stalled at a `contextFill` of 0.41, less than
    /// half the trigger, because the suite had never actually executed against
    /// real hardware to find out (task 5m97h14).
    ///
    /// The list grew from eight turns to ten for the same reason a second time
    /// (task ^wnj3ka3). Eight turns estimated 1836 tokens, which reads as a
    /// comfortable margin over the 1638-token trigger and is not one: the live
    /// run measured 1633 and stopped at a `contextFill` of 0.79736328125, five
    /// tokens short. The estimate counts about 1.23 tokens for each token the
    /// model's own tokenizer counts, so the two added turns are what carry the
    /// live run past the trigger rather than up to it. They sit at the end,
    /// because the first four turns are bounded separately — see
    /// `ScriptedTurnSizingTests/triggerIsNotReachedBeforeAnOldSpanExists()`.
    ///
    /// `ScriptedTurnSizingTests` holds both bounds mechanically, in the tokens
    /// a live run measures, so the fixture can neither shrink below the trigger
    /// nor grow past the working context without a red `swift test`.
    public static let scriptedTurns: [String] = [
        """
        Project brief: this session's internal vault code is CRIMSON-77.
        Remember it precisely; you will be asked about it later. The project
        catalogs a fictional archive of nineteenth-century weather station
        logs from six remote outposts, each reporting barometric pressure,
        wind direction, and temperature three times daily for eleven
        consecutive years. The outposts were staffed on rotating two-year
        postings, so the handwriting changes partway through most volumes and
        the abbreviations used for wind direction change along with it. Two of
        the six kept their readings in a local unit that a later archivist
        converted in pencil directly onto the original page, which means the
        converted figures and the originals now sit side by side with nothing
        marking which is which. The archive also holds the outposts' incoming
        correspondence, which is out of scope for this project but shares the
        same shelf numbering and is easy to pull by mistake. Reply with one
        short sentence acknowledging this.
        """,
        """
        Architecture notes: the archive is split into per-outpost shards,
        each stored as a delimited text file with a fixed-width header
        naming the outpost, its coordinates, and the observer's name for
        that decade. Shards are concatenated chronologically before
        indexing, so ingestion must sort by the header's decade field
        before doing anything else; sorting by filename looks equivalent and
        is not, because three of the outposts were renamed mid-century and
        their files were retitled to match. The delimiter is a tab in the
        earlier shards and a run of spaces in the later ones, a change that
        was never recorded anywhere except in the ingestion code, so the
        reader sniffs the first data line of each shard rather than trusting
        a configured value. Headers are repeated at the top of every page in
        the original volumes and were transcribed each time, so the reader
        also has to drop repeated headers rather than treat them as rows.
        Reply with one short sentence acknowledging this.
        """,
        """
        Data-quality notes: roughly four percent of entries are missing a
        wind-direction reading, always recorded as a bare dash rather than
        omitted entirely, so parsers must treat a lone dash as an explicit
        missing value rather than a parse failure. A smaller share carry an
        obviously transposed temperature decimal, flagged for manual review
        rather than auto-corrected, because the transposition is not always
        recoverable: a reading of 3.71 could plausibly have been 37.1 or
        73.1 depending on the season and the outpost's altitude. Pressure
        readings taken during the two documented instrument replacements
        show a step change of about half a unit that is an artefact of the
        new instrument rather than weather, and the archive's own notes
        disagree with the correspondence about exactly which week each
        replacement happened. None of these are corrected in place; every
        one is annotated. Reply with one short sentence acknowledging this.
        """,
        """
        Indexing notes: the search index keys on outpost name and decade,
        with a secondary index on temperature range so a query for cold
        readings at any outpost in a given decade resolves without a full
        scan. The secondary index is rebuilt lazily, the first time a
        range-style query touches an un-indexed decade, which keeps the
        initial ingest fast at the cost of one slow query per decade per
        process. Outpost names are stored twice, once as transcribed and
        once normalised, because the renames mean a single outpost appears
        under two names across the archive and a reader searching for either
        should find both. The decade field is stored as an integer rather
        than a string so range queries work without lexicographic
        surprises, and the pre-1800 volumes, of which there are only a
        handful, are excluded from the secondary index entirely rather than
        special-cased. Reply with one short sentence acknowledging this.
        """,
        """
        Open questions: whether to normalize pre-1875 pressure readings,
        which used a different reference unit than later entries, and
        whether the six outposts should be weighted equally or by their
        number of surviving entries when computing archive-wide averages,
        since two outposts lost several years of records to a fire. Related
        and unresolved: whether a reading annotated as a suspected
        transposition should be excluded from averages, included as
        transcribed, or included with the correction the annotator
        suggested but did not apply. Excluding them biases the averages
        toward the outposts with tidier record-keeping, and including them
        as transcribed leaves a handful of physically impossible values in
        the summary statistics. There is also no agreement on whether the
        pencil unit conversions should be treated as data or as commentary.
        Reply with one short sentence acknowledging this.
        """,
        """
        Status notes: three of the six outposts have been fully indexed and
        validated against their source shards. The remaining three await a
        second ingestion pass to resolve the missing wind-direction dashes
        described earlier, since the first pass's parser predates that fix
        and silently dropped those rows instead of keeping them as explicit
        missing values. The validation for the finished three compared row
        counts, date continuity, and a sampled hundred readings per decade
        against photographs of the original pages; two transcription errors
        were found and corrected that way, both in the same volume, both in
        the observer name rather than in a reading. The photographs
        themselves are not part of the archive and live on separate
        storage, so the validation is not reproducible from the archive
        alone, which several people have objected to. Reply with one short
        sentence acknowledging this.
        """,
        """
        Further status: no archive-wide statistics should be treated as
        final until all six outposts have passed the second ingestion pass.
        The three already-indexed outposts are believed correct on their
        own, but any statistic mixing outposts across the two ingestion
        passes is provisional, and that includes every headline number
        published so far. The provisional figures have already been quoted
        in two internal write-ups without that caveat attached, which is
        how the current confusion started, and both write-ups now carry a
        correction notice that is easy to miss. Going forward every derived
        figure is stamped with the ingestion-pass state of each outpost it
        draws on, so a reader can tell at a glance whether a number mixes
        passes, and any figure that does is rendered in a way that makes
        the mixture obvious rather than relying on a footnote. Reply with
        one short sentence acknowledging this.
        """,
        """
        Final notes for this session: the second ingestion pass is expected
        to complete within the week, at which point the archive-wide
        averages described earlier can be finalized and the open questions
        about normalization and outpost weighting revisited. The plan is to
        resolve the weighting question first, since the normalization
        decision only changes pre-1875 readings while the weighting
        decision changes every archive-wide figure, and to write both
        decisions down as part of the archive rather than as a separate
        document that can drift away from it. After that the remaining work
        is the transposition annotations, which need a human pass rather
        than a rule, and the question of what to do with the pencil unit
        conversions. Nothing in this list depends on the indexing work,
        which is finished apart from the lazy secondary-index rebuilds.
        Reply with one short sentence acknowledging this.
        """,
        """
        Storage notes: the archive lives in one file for each outpost, with a
        shared index file beside them, and a copy of the whole set is written
        to a second disk every night. The nightly copy is verified by
        comparing a checksum of each file, not by comparing file sizes,
        because a truncated write can leave a file with the correct size and
        the wrong content. Two copies of the index are kept, one written by
        the ingest process and one rebuilt from the outpost files, and a
        difference between them stops the ingest until a person looks at it.
        Nightly copies older than thirty days are removed, which is longer
        than any ingest pass has needed so far. Nothing in the archive is
        stored compressed, because the readers open the files with a memory
        map and a compressed file would have to be expanded first, which
        costs more time than the disk space it saves. Reply with one short
        sentence acknowledging this.
        """,
        """
        Query notes: a reader asks the archive for readings by outpost, by
        date range, or by both, and every answer carries the ingestion-pass
        state of each outpost it draws on. A query that names no outpost
        reads every file, which is slow on the first call of a process and
        fast after that, because the index for each decade stays in memory
        once it is built. A query for a date range that starts before 1800
        skips the secondary index and scans the pre-1800 volumes directly,
        since those volumes are few and are not indexed at all. The answer
        to a query is a list of readings in date order, and readings that
        share a date keep the order they had in the source volume, so a
        reader can compare two answers without sorting either one again.
        Reply with one short sentence acknowledging this.
        """,
    ]
}
