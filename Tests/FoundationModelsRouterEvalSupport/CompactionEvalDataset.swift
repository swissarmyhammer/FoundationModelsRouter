import FoundationModels

/// The kind of thing a fixture's probed fact is, which decides what a fold
/// that loses it costs.
///
/// The dataset held 24 fixtures until task ^k0d30s4 cut it to seven, and the
/// seven that stayed probed an identifier, a number or a duration almost
/// alone. The kind of a fact is not a field the dataset varies, so no bar read
/// it, and the cut lost the one fixture whose probed fact was a rule the user
/// set on the assistant's own later answers (task ^rdsbf57). This marker makes
/// the kind a value `CompactionEvalRepresentativeSubsetTests` can hold.
enum CompactionEvalProbedFactKind: Sendable {
    /// A value a summary can only carry word for word — an identifier, a
    /// slug, a number or a duration. A fold that loses one gives a wrong
    /// answer, and the metric measures whether the summary COPIED the fact.
    case verbatimValue

    /// A rule the user places on the assistant's own later answers — a
    /// constraint every later answer must obey, stated as a fact about the
    /// user as a person. A fold that loses one does harm, not a miss. Its
    /// probed phrase is an ordinary English word, so a summary that dropped
    /// the fact can still answer with a plausible wrong one, and the metric
    /// measures whether the model KEPT the fact.
    case ruleOnLaterAnswers
}

/// One hand-written fixture: facts planted in a seed transcript's head, which
/// fact this fixture's ``question`` probes, and whether the head includes
/// simulated tool traffic (compaction_plan.md §5's "varied lengths, tool
/// traffic, multiple planted facts in the transcript head").
///
/// Kept as plain authored data rather than one bespoke `Transcript` builder
/// per fixture — the content (facts, questions) is what makes each fixture a
/// distinct test case; ``CompactionEvalSeed/build(from:)`` is the single
/// shared assembly path every fixture goes through.
struct CompactionEvalFixtureSpec: Sendable {
    /// A stable id, unique per fixture, threaded through
    /// ``CompactionEvaluationOutcome/seedID`` so ``CompactionEvaluation``
    /// can look the built ``CompactionEvalSeed`` back up from a sample.
    let id: String

    /// Background prose on this fixture's own subject, stated as the first
    /// turn of the foldable head, ahead of every fact turn.
    ///
    /// The fold has to be worth applying, and that is arithmetic rather than
    /// taste. `Compactor.compact` discards a fold whose summary entry is no
    /// smaller than the span it replaces, and
    /// ``Summarization/minimumSummaryTokens`` gives every span this small the
    /// same summary allowance — a floor of 128 tokens, which is 614 bytes of
    /// prose at ``compactionEvalMeasuredBytesPerToken``. A head of one fact
    /// sentence plus its acknowledgement is a few hundred bytes, so the fold
    /// cost more than it saved and the gated run of 2026-08-17 discarded 8 of
    /// 9 of them. This paragraph is what carries the head past that floor;
    /// `CompactionEvalSeedSizingTests` holds every fixture to it mechanically.
    ///
    /// Written per fixture rather than shared, and about this fixture's own
    /// subject, so no two seeds fold the same span. It never states
    /// ``factKeyPhrase`` — a key phrase the background carried would let a
    /// summary answer the question without the planted fact ever surviving,
    /// which is the opposite of what this dataset measures.
    /// `CompactionEvaluationHermeticTests/everySeedStatesItsKeyPhraseExactlyOnce`
    /// pins that.
    let context: String

    /// The facts stated, in order, in the transcript's foldable head — one
    /// dedicated turn per fact. Every fixture states at least one; several
    /// state two or three, exercising "multiple planted facts in the head".
    let facts: [String]

    /// Which of ``facts`` this fixture's ``question`` is answerable from —
    /// an index into `facts`.
    let probedFactIndex: Int

    /// The short, distinctive token or value from `facts[probedFactIndex]`
    /// that a correct answer should contain verbatim — e.g. `"CRIMSON-77"`
    /// for `facts[probedFactIndex]` = `"The project's internal vault code is
    /// CRIMSON-77; ..."`.
    ///
    /// Deliberately **not** the full fact sentence: `FactRetention`
    /// (``CompactionEvaluation/evaluators``) checks whether the model's
    /// short, targeted answer *contains* this value — a short answer can
    /// never contain an entire long declarative sentence as a substring, so
    /// using the full sentence there would make the metric fail
    /// unconditionally regardless of whether compaction actually preserved
    /// the fact.
    let factKeyPhrase: String

    /// What kind of thing `facts[probedFactIndex]` states, so the shape of the
    /// answer ``question`` asks for. No other field carries it: the fact count,
    /// the probed position, the delivery and the recency window all vary, and
    /// a fixture can change kind while every one of them stays the same.
    let probedFactKind: CompactionEvalProbedFactKind

    /// The question asked of the resumed, post-compaction session — answerable
    /// only from `facts[probedFactIndex]`, never from the untouched recency
    /// window.
    let question: String

    /// Whether the probed fact's turn is delivered via a simulated tool call
    /// + tool output pair (realistic agentic tool traffic) rather than a
    /// plain assistant reply.
    let probedFactViaTool: Bool

    /// How many filler turns pad the untouchable recency window — varies the
    /// fixture's overall transcript length. Always at least the
    /// `ToolOutputElision`/`TurnTruncation` default `keepRecentTurns` (4), so
    /// every probed fact's turn is provably outside the recency window.
    let recentTurnCount: Int
}

/// One filler turn: the line that prompts it and the reply the assistant gives
/// it, kept together so the two can never drift apart.
struct CompactionEvalFillerTurn: Sendable {
    /// The filler line, asked as the turn's prompt.
    let prompt: String

    /// The assistant's reply to ``prompt`` — a plausible answer to that
    /// specific line, and distinct from every other reply in this pool and in
    /// ``compactionEvalFactAcknowledgements``.
    let reply: String
}

/// A pool of filler turns padding every fixture's untouchable recency window —
/// content that pads the transcript but is never itself the subject of a
/// question.
///
/// Every reply differs from every other, and the pool is longer than the
/// largest ``CompactionEvalFixtureSpec/recentTurnCount``, so cycling can never
/// repeat a turn inside one fixture's recency window. That is the property
/// `CompactionEvaluationHermeticTests.noSeedRepeatsAnAssistantReply` pins, and
/// it is load-bearing rather than cosmetic: the gated run of 2026-08-09
/// measured 18 of 19 `factRetention` failures answering with the single canned
/// reply every statement turn then shared, which is pattern completion over
/// the model's own visible transcript rather than a verdict on the summary
/// above it. A dataset whose recency window repeats one string cannot tell
/// those two apart.
let compactionEvalFillerTurns: [CompactionEvalFillerTurn] = [
    CompactionEvalFillerTurn(
        prompt: "By the way, what's a good one-word codename for a low-priority task?",
        reply: "\"Pebble\" would suit something low-priority."
    ),
    CompactionEvalFillerTurn(
        prompt: "Quick check: does this conversation still make sense to you so far?",
        reply: "Yes, everything so far follows."
    ),
    CompactionEvalFillerTurn(
        prompt: "Unrelated question: name any color that isn't blue.",
        reply: "Amber."
    ),
    CompactionEvalFillerTurn(
        prompt: "Just chatting — what's a common synonym for \"quick\"?",
        reply: "\"Rapid\" is the usual one."
    ),
    CompactionEvalFillerTurn(
        prompt: "Give me a one-word synonym for \"finished\".",
        reply: "Complete."
    ),
    CompactionEvalFillerTurn(
        prompt: "Say any short greeting.",
        reply: "Hello there."
    ),
    CompactionEvalFillerTurn(
        prompt: "One more aside: name a month with exactly thirty days.",
        reply: "September runs to thirty days."
    ),
    CompactionEvalFillerTurn(
        prompt: "Last aside: what's the opposite of \"early\"?",
        reply: "Late."
    ),
]

/// The acknowledgements the assistant gives a fact-bearing statement turn, one
/// per fact in fixture order.
///
/// Distinct from one another and from every ``CompactionEvalFillerTurn/reply``,
/// for the reason ``compactionEvalFillerTurns`` states, and longer than the
/// largest fixture's fact count so no fixture repeats one. Deliberately
/// content-free: an acknowledgement that restated its fact would put the fact
/// itself in the reply, and the variable under test is reply homogeneity
/// alone — never how much of the fact the transcript repeats.
let compactionEvalFactAcknowledgements: [String] = [
    "Got it — I'll keep that in mind.",
    "Understood; thanks for the heads-up.",
    "Right, I'll remember that.",
    "Sure, that's clear.",
]

/// The acknowledgement the assistant gives every fixture's
/// ``CompactionEvalFixtureSpec/context`` turn.
///
/// One string rather than a pool, because each seed states its background
/// exactly once, so this can never repeat inside one transcript. Distinct from
/// every ``compactionEvalFactAcknowledgements`` entry and every
/// ``CompactionEvalFillerTurn/reply`` for the reason
/// ``compactionEvalFillerTurns`` states, and content-free for the reason
/// ``compactionEvalFactAcknowledgements`` states.
let compactionEvalContextAcknowledgement = "Noted — I have the background in mind."

/// Every hand-written fixture: seven seed transcripts spanning single- and
/// multi-fact heads, plain-reply and tool-traffic delivery, short-to-long
/// recency windows, and both kinds of probed fact — a value the summary can
/// only copy, and a rule on the assistant's own later answers.
///
/// These are exactly the seeds ``compactionEvalRepresentativeSubsetIDs`` names,
/// which is the whole dataset the one gated fact-retention tier measures. The
/// dataset held 24 fixtures until task ^k0d30s4, of which a second gated tier
/// measured all 24 and this tier measured these seven. A tier of 24 seeds costs
/// more than six minutes at the canary's own measured rate, so it could not
/// hold that task's two-minute budget for every integration test, and the user
/// answered it by making the TEST smaller rather than by keeping a tier no
/// everyday command runs: the seventeen fixtures no gated tier would have
/// folded went with it.
///
/// So the dataset and the gated tier now hold the same seeds. What the seven
/// must carry between them is held by
/// `CompactionEvalRepresentativeSubsetTests`, which reads them against absolute
/// bars rather than against the dataset — a comparison of the dataset with
/// itself would state nothing.
let compactionEvalFixtureSpecs: [CompactionEvalFixtureSpec] = [
    CompactionEvalFixtureSpec(
        id: "sesame-allergy",
        context: """
            Background for this session: I do most of the cooking at home for a household of four, and I
            plan the week's dinners on a Sunday so that one big shop covers everything. Two of us take a
            packed lunch, so most dinners are cooked in a quantity that leaves a portion over, and a recipe
            that does not scale up cleanly is more trouble than it is worth. A weeknight gets about forty
            minutes from starting to sitting down, and anything longer is kept for the weekend. The kitchen
            is small, with one oven and four rings, so a menu that needs the oven at two temperatures at once
            does not work for us. We eat a fair amount of fish and not much red meat, and I keep a stocked
            spice shelf and a freezer full of stock, so a recipe can assume both. When I ask you for a recipe
            or a menu, I want the ingredient list first and the method second, with quantities in grams
            rather than cups, because the scales are easier to trust than the measuring cups. I cook from a
            phone propped on the counter, so a method of short numbered steps is much easier to follow than
            a long paragraph. Reply with one short sentence acknowledging this.
            """,
        facts: [
            "I have a severe allergy to sesame, so never put it — the seeds, the oil or tahini — into any recipe or menu you give me."
        ],
        probedFactIndex: 0,
        factKeyPhrase: "sesame",
        probedFactKind: .ruleOnLaterAnswers,
        question: "Which ingredient must you leave out of every recipe and menu you give me, and why?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "db-port",
        context: """
            Background for this session: the staging environment runs its own copy of the database, restored
            from a nightly sanitised dump of production, so the shape of the data is realistic while nothing
            in it identifies a real person. The restore runs before the working day starts and takes about
            forty minutes, and a restore that fails leaves yesterday's copy in place rather than an empty
            database. Schema migrations are applied to staging first and are expected to sit there for at
            least a day before they reach production. The instance is deliberately smaller than the
            production one, so a query that is slow in staging is usually slow in production too, and a
            query that is fast in staging proves very little. Connections from developer machines go through
            a bastion host rather than directly, and the bastion closes an idle session after thirty
            minutes. There is a read-only replica beside the primary for reporting work, and it lags the
            primary by a few seconds. The replica is not used by the application at all, only by the
            reporting tool, so a reader that needs current data has to ask the primary and accept the extra
            load that comes with it. Reply with one short sentence acknowledging this.
            """,
        facts: ["The staging database listens on port 6543, not the default 5432."],
        probedFactIndex: 0,
        factKeyPhrase: "6543",
        probedFactKind: .verbatimValue,
        question: "What port does the staging database listen on?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "license-key-and-region",
        context: """
            Background for this session: the analytics tool has been chosen after a short evaluation against
            two alternatives, and the decision came down to how the three handled data residency rather than
            to their feature lists. The tool is billed per seat rather than per event, so the cost is
            predictable and adding a dashboard viewer is cheap, which is why read-only access is being given
            fairly widely rather than rationed. Instrumentation is added by the team that owns each surface
            rather than by a central group, and every event carries a schema that is reviewed before it
            ships, because an event with a badly chosen field is far harder to fix once dashboards depend on
            it. Historical data is retained for thirteen months so that a year-over-year comparison always
            has a full prior year behind it. The tool is reached through a single account rather than one
            per environment, and staging events are separated by a flag on the event rather than by a
            separate project. The evaluation also compared how the three exported raw data, because the team
            wants to keep a copy of every event in its own storage rather than depend on the tool for
            history. Reply with one short sentence acknowledging this.
            """,
        facts: [
            "The license key for the analytics tool is stored in the team password manager under \"analytics-prod\".",
            "The production deployment region is eu-west-2, chosen for data-residency reasons.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "eu-west-2",
        probedFactKind: .verbatimValue,
        question: "Which region is the production deployment in, and why was it chosen?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "budget-cap-tool-and-owner",
        context: """
            Background for this session: the project runs entirely on managed cloud services, with no
            machines the team looks after itself, and the bill is dominated by three line items rather than
            spread evenly. Object storage grows steadily and predictably, the managed database is a fixed
            monthly amount, and the compute cost moves with traffic and is the only part that can surprise
            anyone. Costs are reviewed monthly against the forecast, and a variance of more than about a
            tenth either way is expected to come with an explanation rather than a shrug. Every resource
            carries a tag naming the project it belongs to, and an untagged resource is reported weekly
            until someone claims it. The team has already taken one large saving by moving cold objects to a
            cheaper storage class after thirty days, and a second by turning off the staging environment
            overnight and at weekends, which nobody has missed. A fourth line item, data transfer out of the
            region, was large enough last quarter to be noticed and turned out to be a misconfigured backup
            copying across regions nightly. Reply with one short sentence acknowledging this.
            """,
        facts: [
            "The monthly cloud spend cap for this project is $4,200.",
            "Any spend increase above the cap needs written approval from the finance owner, Marcus.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "4,200",
        probedFactKind: .verbatimValue,
        question: "What is the monthly cloud spend cap for this project?",
        probedFactViaTool: true,
        recentTurnCount: 6
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-support-escalation",
        context: """
            Background for this session: support is staffed across two time zones, which covers most but not
            all of the clock, and the gap is handled by the on-call rotation rather than by asking anyone to
            work overnight. Tickets arrive through one queue regardless of how the customer contacted us,
            and they are triaged on arrival rather than picked up in order, because a login outage and a
            question about billing do not deserve the same wait. The tiers are about depth rather than
            seniority: the first tier handles anything with a documented answer, and the second handles
            anything that needs the code read. Every escalation carries a written summary of what has
            already been tried, which is the single thing that most affects how quickly the next person can
            help. Response times are measured from the customer's first message rather than from triage, and
            the measurement is published internally each week. Every ticket is tagged with the area it
            touches, and the tags are reviewed monthly to find the questions that keep arriving, which is
            where most of the documentation work comes from. Reply with one short sentence acknowledging
            this.
            """,
        facts: [
            "Tier-1 support tickets escalate to tier-2 after 2 hours with no response.",
            "Tier-2 support tickets escalate to the on-call engineer after 6 hours with no response.",
            "The on-call escalation contact this week is Dana, reachable via the pager rotation.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "2 hours",
        probedFactKind: .verbatimValue,
        question: "After how long does a tier-1 support ticket escalate to tier-2?",
        probedFactViaTool: false,
        recentTurnCount: 7
    ),
    CompactionEvalFixtureSpec(
        id: "encryption-algorithm",
        context: """
            Background for this session: the project handles customer records and is reviewed against an
            external standard once a year, which shapes several decisions that would otherwise be left to
            preference. Data in transit is protected end to end, with the modern protocol version only and
            no fallback to the older ones, and the certificates are issued automatically and rotate every
            few months. Keys are held in a managed service rather than in the application, and the
            application never sees a raw key: it asks the service to wrap and unwrap, so a compromised
            application host does not hand over the keys with it. Access to the key service is logged and
            the logs are kept for a year. Backups are protected with the same scheme as the live data, on
            the reasoning that a backup is simply data at rest somewhere else, and a restore is tested
            quarterly rather than assumed to work when it is needed. Field-level protection is applied to
            two columns beyond the whole-database layer, because those two are readable by a reporting job
            that has no reason to see them in the clear. Reply with one short sentence acknowledging this.
            """,
        facts: ["Data at rest in this project is encrypted with AES-256-GCM, never the older CBC mode."],
        probedFactIndex: 0,
        factKeyPhrase: "AES-256-GCM",
        probedFactKind: .verbatimValue,
        question: "Which encryption mode is used for data at rest in this project?",
        probedFactViaTool: true,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-long-project-brief",
        context: """
            Background for this session: the cataloguing effort under discussion is funded for two years and
            is one of four running in parallel across the same institution, sharing a single ingest pipeline
            and a single search index between them. That sharing is the source of most of the constraints: a
            change to the pipeline has to be agreed with the other three, and a field one project wants is a
            field the others have to tolerate. The material is fragile and is handled once, photographed,
            and then worked from the photographs, so a transcription error found later is corrected against
            the image rather than against the original. Two archivists work on transcription and one on
            quality control, and the quality control is sampled rather than exhaustive. Progress is reported
            monthly against a target that was set before anyone had seen the handwriting, and the target has
            been revised once already for that reason. The search index is rebuilt weekly rather than
            continuously, so a correction made on a Monday is not visible to a reader until the following
            week, which several people have asked to change. Reply with one short sentence acknowledging
            this.
            """,
        facts: [
            "This project catalogs nineteenth-century weather station logs from six remote outposts.",
            "Each outpost reports barometric pressure, wind direction, and temperature three times daily.",
            "The archive's internal reference id for this cataloging effort is WX-ARCHIVE-6.",
        ],
        probedFactIndex: 2,
        factKeyPhrase: "WX-ARCHIVE-6",
        probedFactKind: .verbatimValue,
        question: "What is the internal reference id for this weather-archive cataloging effort?",
        probedFactViaTool: false,
        recentTurnCount: 6
    ),
]

/// Builds every fixture's ``CompactionEvalSeed``, keyed by
/// ``CompactionEvalFixtureSpec/id``. Computed once, lazily, and reused by
/// every ``CompactionEvaluation`` instance built over this module (each
/// points at the same dataset, differing only in the ``CompactionPrompt``
/// under test).
let compactionEvalSeeds: [CompactionEvalSeed] = compactionEvalFixtureSpecs.map(CompactionEvalSeed.build(from:))

/// The fixtures the one gated real-model tier measures.
///
/// Every seed costs two real generations, one summarizer call inside the fold
/// and one answering turn on the resumed session, so a tier is priced in seeds:
/// ``compactionEvalSubsetTimeLimitMinutes`` derives its wall clock from this
/// count. Seven is what fits task ^k0d30s4's two-minute budget for every
/// integration test, and the dataset was cut to these seven when the user
/// settled that budget, so this list and ``compactionEvalFixtureSpecs`` now name
/// the same fixtures. It is still stated separately, because it is what the tier
/// ASKS FOR — a run that measured fewer seeds than this list names has left
/// seeds unreached, and ``CompactionEvalFactRetentionReport`` says which.
///
/// Chosen for coverage. Four things vary across them — how many facts the
/// foldable head states, which of them the question probes, whether the probed
/// fact arrives as tool traffic or as a plain reply, and how many filler turns
/// pad the untouchable recency window. Each member is here for a property it
/// carries, and together they span all four:
///
/// | fixture | head | probed fact | delivery | recency window |
/// |---|---|---|---|---|
/// | `sesame-allergy` | one fact | the only one | plain reply | 4 — the shortest here |
/// | `db-port` | one fact | the only one | tool traffic | 4 |
/// | `encryption-algorithm` | one fact | the only one | tool traffic | 5 |
/// | `license-key-and-region` | two facts | the second, so the last of its head | plain reply | 4 |
/// | `budget-cap-tool-and-owner` | two facts | the first, so a fact the summary must reach past its sibling for | tool traffic | 6 |
/// | `three-facts-support-escalation` | three facts | the first of three | plain reply | 7 — the longest here |
/// | `three-facts-long-project-brief` | three facts | the third, so the last of its head | plain reply | 6 |
///
/// A fifth thing varies, and only one seed carries its harder side: the KIND
/// of the probed fact, ``CompactionEvalFixtureSpec/probedFactKind``. Six seeds
/// probe a value a summary can only copy word for word. `sesame-allergy` probes
/// a rule the user places on the assistant's own later answers, stated as a fact
/// about the user as a person and in a domain that is not software; task
/// ^rdsbf57 rewrote it from the `env-file` fixture for that kind, because the
/// cut of ^k0d30s4 had left the seven without one.
///
/// `CompactionEvalRepresentativeSubsetTests` holds that coverage mechanically,
/// against ABSOLUTE bars rather than against the dataset. It read the dataset
/// while a second tier measured a wider one; now that the two hold the same
/// seeds, a comparison with the dataset would pass whatever this list named.
let compactionEvalRepresentativeSubsetIDs: [String] = [
    "sesame-allergy",
    "db-port",
    "encryption-algorithm",
    "license-key-and-region",
    "budget-cap-tool-and-owner",
    "three-facts-support-escalation",
    "three-facts-long-project-brief",
]

/// The built seeds of ``compactionEvalRepresentativeSubsetIDs``, in the order
/// ``compactionEvalFixtureSpecs`` states them.
///
/// Filtered out of ``compactionEvalSeeds`` rather than built from a second list
/// of specs, so a seed the gated tier folds is the same seed every hermetic test
/// of this dataset reads, under one fixture id.
let compactionEvalRepresentativeSeeds: [CompactionEvalSeed] = compactionEvalSeeds.filter {
    compactionEvalRepresentativeSubsetIDs.contains($0.id)
}
