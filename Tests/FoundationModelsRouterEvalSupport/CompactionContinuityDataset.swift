/// One hand-written multi-step task: a handful of setup steps that each
/// plant one fact, padded with filler steps, followed by a final instruction
/// whose correct completion requires combining the planted facts — answerable
/// only if the session stayed *continuable* across whatever folds its own
/// small budget forced along the way, not merely if a single fold's summary
/// happened to be good (``CompactionEvaluation``'s own, narrower concern).
///
/// Kept as plain authored data rather than one bespoke step sequence per
/// fixture — the content (facts, final instruction) is what makes each
/// fixture a distinct test case; ``CompactionContinuitySeed/build(from:)`` is
/// the single shared assembly path every fixture goes through.
struct CompactionContinuityTaskSpec: Sendable {
    /// A stable id, unique per fixture, threaded through
    /// ``CompactionContinuityOutcome/taskID`` so ``CompactionContinuityEvaluation``
    /// can look the built ``CompactionContinuitySeed`` back up from a sample.
    let id: String

    /// The facts stated, in order, one dedicated setup step per fact — all
    /// of them required by ``finalInstruction`` to complete correctly.
    let facts: [String]

    /// The short, distinctive value from each of ``facts`` a correct
    /// completion of ``finalInstruction`` should contain verbatim — parallel
    /// to ``facts``. See ``CompactionEvalFixtureSpec/factKeyPhrase``'s own
    /// doc comment for why a short key phrase, never the whole fact
    /// sentence, is what gets checked.
    let factKeyPhrases: [String]

    /// How many filler steps pad the task between the setup steps and
    /// ``finalInstruction`` — sized per fixture so the whole task's
    /// cumulative length, against ``CompactionContinuityEvaluation/budget``,
    /// is impossible to complete without at least one live fold along the
    /// way (this dataset's own "sized to be impossible without >=1 fold"
    /// requirement, distinct from ``CompactionEvalFixtureSpec``'s fixed
    /// `recentTurnCount`, which only pads the untouched recency window).
    let fillerStepCount: Int

    /// The final step: an instruction whose correct completion requires
    /// every one of ``facts``, asked only after every setup step and every
    /// filler step, so a session that lost continuity across its own folds
    /// cannot complete it correctly.
    let finalInstruction: String

    /// Every key phrase (mirrors ``factKeyPhrases``) a fully correct
    /// completion of ``finalInstruction`` must contain — the ground truth
    /// ``CompactionContinuityMetric/answersCorrect`` checks against.
    var expectedKeyPhrases: [String] { factKeyPhrases }
}

/// A small, reused pool of filler steps padding a task between its setup
/// steps and its final instruction — content that pads the task but is
/// never itself the subject of ``CompactionContinuityTaskSpec/finalInstruction``,
/// so its variety (or lack of it) does not affect dataset diversity. Mirrors
/// ``compactionEvalFillerTurns``'s own convention.
///
/// Each step is a substantial paragraph rather than a one-line aside, and the
/// length is the point, not decoration: a step's job here is to *consume
/// context*, and ten of these have to estimate past
/// ``compactionContinuityDefaultBudget``'s ``TokenBudget/triggerTokens`` (1638)
/// on their own for any task built from them to force a live fold.
/// `CompactionContinuityEvaluationTests.everyTaskIsSizedToForceAFold` asserts
/// exactly that. The one-line versions these replaced estimated about 14 tokens
/// each — roughly an eleventh of what the trigger needs — and the sizing test
/// of the day never noticed, because it counted steps instead of tokens (task
/// 5m97h14).
///
/// Every step still closes by asking for a trivial one-word or one-sentence
/// answer, so the model's own replies stay short and the padding is all on the
/// prompt side, and none of them mentions any fixture's planted facts.
let compactionContinuityFillerSteps: [String] = [
    """
    By the way, here is a tangent with no bearing at all on anything above. \
    Our team keeps arguing about how to label the tickets nobody plans to pick \
    up this quarter. One camp wants strictly numeric identifiers, on the \
    grounds that a bare number cannot be misread as a priority signal, and \
    that anything more expressive invites people to read urgency into a label \
    that was never meant to carry it. Another camp insists on short evocative \
    words, because a memorable label is far easier to raise in conversation \
    than a five-digit string nobody can recall under pressure. A third group \
    has proposed borrowing from botany, on the theory that plant names are \
    plentiful, pronounceable, and carry no accidental connotations of urgency \
    whatsoever. Nobody has persuaded anybody, and the argument has now \
    outlasted several of the tickets it was about. Ignore all of that context \
    and simply answer the question: what is one good single word to use as a \
    codename for a task nobody considers urgent? Reply with just that one \
    word and nothing else.
    """,
    """
    Setting the earlier material aside entirely for a moment, here is an aside \
    about how long exchanges like this one tend to go. People often assume a \
    lengthy conversation degrades steadily, as though every additional \
    paragraph blurs whatever came before it by some fixed amount. In practice \
    the failure is much lumpier than that: whole stretches stay perfectly \
    crisp while one specific detail quietly evaporates, and it is almost \
    always the detail nobody thought to repeat. That is why careful \
    interviewers double back on the same question in different words rather \
    than trusting a single answer, and why good notes get taken during a \
    discussion instead of reconstructed afterward from memory. The same \
    asymmetry shows up in written records: the summary someone wrote at the \
    time is usually more reliable than the far longer account assembled from \
    recollection weeks later. None of which needs any analysis from you. Just \
    confirm that you are still following this exchange, in one short \
    sentence, and say nothing further.
    """,
    """
    Here is an entirely unrelated digression, offered purely as padding. \
    Colour naming across languages is far less uniform than most people \
    expect. Some languages draw the boundary between green and blue in a place \
    English speakers would find arbitrary; others have a single basic term \
    covering both, and speakers of those languages have no more trouble \
    describing the sky than anybody else. Several languages have separate \
    basic terms for light and dark shades of what English treats as one colour \
    with a modifier attached. The order in which languages acquire basic \
    colour terms turns out to be strikingly consistent even so, which is one \
    of the more famous findings in the field and one of the more heavily \
    argued over. Weavers, dyers, and printers each carry their own vocabulary \
    on top of all that, finer grained than the everyday one and mutually \
    unintelligible. You do not need to engage with any of it. Simply name any \
    single colour that is not blue, and reply with nothing but that colour's \
    name.
    """,
    """
    Just chatting, with nothing here that connects to the work above. English \
    is unusually rich in words for doing something in a short span of time, \
    and the shades between them are real rather than stylistic. One implies \
    haste and the mistakes that come with it; another implies practised \
    efficiency with no mistakes at all; a third implies suddenness, which is \
    about the beginning of an action rather than its duration. A fourth is \
    mostly about impatience on the part of whoever is waiting. Translators \
    tend to find this cluster harder than technical vocabulary, because a \
    specialist term usually has one correct counterpart while an everyday \
    word has a dozen near ones, each wrong in a different direction. Style \
    guides are not much help either, since they mostly advise picking the \
    shortest option and moving on. Skip all of that and answer plainly: give \
    one common synonym for the word "quick", and reply with that single word \
    only.
    """,
    """
    Another interlude, unconnected to everything else in this conversation. \
    Words for the state of being complete carry a surprising amount of \
    baggage. Some suggest that the work stopped because it reached its natural \
    end, others that it stopped because someone decided to stop, and the \
    difference matters enormously in a status report even though both describe \
    the same halted activity. A few carry an implication of polish, meaning \
    not merely ended but brought to a good standard, which is why they get \
    used in advertising far more often than in engineering. Project managers \
    have invented elaborate vocabularies to keep these apart, with tiers for \
    work that is done, work that is done pending review, and work that is \
    done pending a review that has been scheduled but not held. None of that \
    taxonomy is needed here. Give one single-word synonym for "finished", and \
    reply with nothing but that word.
    """,
    """
    One last aside before we continue, and it has no connection to any of the \
    preceding material. Greetings are among the most heavily ritualised parts \
    of any language, and among the first things a learner is taught, precisely \
    because getting one wrong is noticed immediately while an awkward sentence \
    in the middle of a paragraph usually is not. Their literal meanings are \
    frequently beside the point: several common ones are questions nobody \
    expects an answer to, and others are abbreviated blessings whose original \
    sense has worn away entirely from centuries of use. Length signals \
    formality more reliably than vocabulary does, which is why the shortest \
    options travel best between contexts and why written correspondence keeps \
    inventing new short ones. There is nothing to analyse here. Say any short \
    greeting, and reply with nothing else.
    """,
]

/// The smallest filler padding a fixture carries between its setup steps
/// and its final instruction. Ten steps size a task past
/// ``compactionContinuityDefaultBudget``'s trigger —
/// `CompactionContinuityEvaluationTests.everyTaskIsSizedToForceAFold` holds
/// that property by token estimate, never by step count.
let compactionContinuityShortFillerStepCount = 10

/// The middle filler padding some fixtures carry — one step more than
/// ``compactionContinuityShortFillerStepCount``, so the dataset's tasks do
/// not all have the same length.
let compactionContinuityMediumFillerStepCount = 11

/// The largest filler padding a fixture carries — two steps more than
/// ``compactionContinuityShortFillerStepCount``.
let compactionContinuityLongFillerStepCount = 12

/// Every hand-written multi-step task fixture (task 4ce0a1k): each requires
/// at least one live fold to complete, since ``fillerStepCount`` pads every
/// task well past ``CompactionContinuityEvaluation``'s own small default
/// budget before ``finalInstruction`` is ever asked.
let compactionContinuityTaskSpecs: [CompactionContinuityTaskSpec] = [
    CompactionContinuityTaskSpec(
        id: "vault-code-and-outpost",
        facts: [
            "This project's internal vault code is CRIMSON-77.",
            "The vault is physically located at outpost Delta-9.",
        ],
        factKeyPhrases: ["CRIMSON-77", "Delta-9"],
        fillerStepCount: compactionContinuityShortFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state this project's exact vault code and which outpost the vault is located at."
    ),
    CompactionContinuityTaskSpec(
        id: "db-port-and-region",
        facts: [
            "The staging database listens on port 6543, not the default 5432.",
            "The staging database's region is eu-west-2.",
        ],
        factKeyPhrases: ["6543", "eu-west-2"],
        fillerStepCount: compactionContinuityShortFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the exact port the staging database listens on and which region it runs in."
    ),
    CompactionContinuityTaskSpec(
        id: "release-branch-and-reviewer",
        facts: [
            "Releases are cut from the `release/stable` branch, never directly from `main`.",
            "Every release needs sign-off from Priya before it ships.",
        ],
        factKeyPhrases: ["release/stable", "Priya"],
        fillerStepCount: compactionContinuityLongFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state which branch releases are cut from and whose sign-off a release needs before shipping."
    ),
    CompactionContinuityTaskSpec(
        id: "flight-and-gate",
        facts: [
            "The user's return flight number is BA-249.",
            "That flight departs from gate 12.",
        ],
        factKeyPhrases: ["BA-249", "gate 12"],
        fillerStepCount: compactionContinuityShortFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the user's exact return flight number and which gate it departs from."
    ),
    CompactionContinuityTaskSpec(
        id: "codename-and-owner",
        facts: [
            "The internal codename for the new feature is \"Project Longbow\".",
            "Project Longbow's owner is Marcus.",
        ],
        factKeyPhrases: ["Longbow", "Marcus"],
        fillerStepCount: compactionContinuityMediumFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the internal codename for the new feature and who owns it."
    ),
    CompactionContinuityTaskSpec(
        id: "hostname-and-datacenter",
        facts: [
            "The internal staging server's hostname is `stg-node-07.internal`.",
            "That server lives in the eastern datacenter.",
        ],
        factKeyPhrases: ["stg-node-07", "eastern"],
        fillerStepCount: compactionContinuityShortFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the internal staging server's exact hostname and which datacenter it lives in."
    ),
    CompactionContinuityTaskSpec(
        id: "migration-script-and-rollback",
        facts: [
            "The database migration script lives at `scripts/migrate_2026_07.sql`.",
            "Its rollback script lives at `scripts/rollback_2026_07.sql`.",
        ],
        factKeyPhrases: ["migrate_2026_07", "rollback_2026_07"],
        fillerStepCount: compactionContinuityLongFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the exact path to the migration script and the exact path to its rollback script."
    ),
    CompactionContinuityTaskSpec(
        id: "spend-cap-and-owner",
        facts: [
            "The monthly cloud spend cap for this project is $4,200.",
            "Any spend increase above the cap needs written approval from Marcus.",
        ],
        factKeyPhrases: ["4,200", "Marcus"],
        fillerStepCount: compactionContinuityMediumFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state the exact monthly cloud spend cap and who must approve any increase above it."
    ),
    CompactionContinuityTaskSpec(
        id: "wifi-and-policy",
        facts: [
            "The office wifi password is printed on the back of the router.",
            "Guests must sign in at the front desk before receiving it.",
        ],
        factKeyPhrases: ["router", "front desk"],
        fillerStepCount: compactionContinuityShortFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state where the office wifi password is printed and where guests must sign in before receiving it."
    ),
    CompactionContinuityTaskSpec(
        id: "escalation-and-contact",
        facts: [
            "Tier-1 support tickets escalate to tier-2 after 2 hours with no response.",
            "The on-call escalation contact this week is Dana.",
        ],
        factKeyPhrases: ["2 hours", "Dana"],
        fillerStepCount: compactionContinuityLongFillerStepCount,
        finalInstruction:
            "Without re-reading anything, state how long before a tier-1 ticket escalates and who this week's on-call escalation contact is."
    ),
]

/// Builds every fixture's ``CompactionContinuitySeed``, keyed by
/// ``CompactionContinuityTaskSpec/id``. Computed once, lazily, and reused by
/// every ``CompactionContinuityEvaluation`` instance constructed in this
/// target (each points at the same dataset, differing only in the
/// ``CompactionPrompt`` under test).
let compactionContinuitySeeds: [CompactionContinuitySeed] = compactionContinuityTaskSpecs.map(CompactionContinuitySeed.build(from:))

/// How many durable transcript entries one driven step records: the prompt
/// entry and the response entry of its prompt/response pair. Each seed
/// builder multiplies its step count by this value, and adds the one leading
/// `.instructions` entry, to state
/// ``CompactionContinuitySeed/expectedMinimumRecordedEntries``.
let compactionContinuityRecordedEntriesPerStep = 2

/// A built multi-step task ready to hand to a session-driving subject: the
/// ordered steps to send before the final instruction, the final instruction
/// itself, the key phrases a correct completion must contain, and the
/// ground-truth minimum recorded-entry count a fully durable recording of
/// the whole task should produce.
///
/// Kept separate from ``CompactionContinuityOutcome`` (the `Codable` type
/// that actually travels through the ``Evaluations`` framework's
/// `ModelSample`/`ModelSubject`) for the same reason
/// ``CompactionEvalSeed`` is: a sample only needs to carry ``id``, and
/// ``CompactionContinuityEvaluation`` looks the full seed back up from its
/// own in-memory table.
struct CompactionContinuitySeed: Sendable {
    /// Mirrors ``CompactionContinuityTaskSpec/id``.
    let id: String

    /// Every step to send, in order, before ``finalInstruction`` — one setup
    /// step per planted fact, then the filler steps.
    let steps: [String]

    /// The final step: see ``CompactionContinuityTaskSpec/finalInstruction``.
    let finalInstruction: String

    /// Mirrors ``CompactionContinuityTaskSpec/factKeyPhrases`` — every
    /// individual planted fact's key phrase, checked independently by
    /// ``CompactionContinuityMetric/factsSurvived``.
    let factKeyPhrases: [String]

    /// Mirrors ``CompactionContinuityTaskSpec/expectedKeyPhrases`` — every
    /// key phrase a fully correct completion must contain together, checked
    /// by ``CompactionContinuityMetric/answersCorrect``.
    let expectedKeyPhrases: [String]

    /// The ground-truth minimum number of recorded transcript entries a
    /// fully durable recording of this task should produce: one leading
    /// `.instructions` entry plus one prompt/response pair per step
    /// (``steps`` plus the final instruction) — checked by
    /// ``CompactionContinuityMetric/recordingComplete`` against whatever the
    /// real subject's own recording actually persisted, proving the fold(s)
    /// along the way never dropped anything from the durable history (only
    /// ever from the *live*, resumable window — compaction_plan.md's whole
    /// point).
    let expectedMinimumRecordedEntries: Int

    /// Builds a seed from a hand-written fixture spec: one setup step per
    /// fact, then `spec.fillerStepCount` filler steps drawn from
    /// ``compactionContinuityFillerSteps`` (cycled if a fixture asks for
    /// more filler steps than the pool has), then the final instruction.
    ///
    /// - Parameter spec: The fixture to build.
    /// - Returns: The assembled seed.
    static func build(from spec: CompactionContinuityTaskSpec) -> CompactionContinuitySeed {
        let factSteps = spec.facts
        let fillerSteps = (0..<spec.fillerStepCount).map { offset in
            compactionContinuityFillerSteps[offset % compactionContinuityFillerSteps.count]
        }
        let totalStepCount = factSteps.count + fillerSteps.count + 1

        return CompactionContinuitySeed(
            id: spec.id,
            steps: factSteps + fillerSteps,
            finalInstruction: spec.finalInstruction,
            factKeyPhrases: spec.factKeyPhrases,
            expectedKeyPhrases: spec.expectedKeyPhrases,
            expectedMinimumRecordedEntries: 1 + totalStepCount * compactionContinuityRecordedEntriesPerStep
        )
    }

    /// Keys `tasks` by ``finalInstruction``, the join a running sample already
    /// carries back to the task it is driving.
    ///
    /// ``CompactionContinuityEvaluation/dataset`` stamps each sample's prompt
    /// with its task's own final instruction, and
    /// ``CompactionContinuityEvalRealSubjectRunner/run(steps:finalInstruction:prompt:budget:)``
    /// receives that same string, so this is what lets a live progress line name
    /// the task a sample is running. Mirrors
    /// ``CompactionEvalSeed/keyedByQuestion(_:)``.
    ///
    /// Two tasks stating one final instruction would be a fixture defect rather
    /// than something to resolve here, so the first wins — see
    /// ``Swift/Sequence/keyedByFirst(_:)``, the one body both tiers build their
    /// join through.
    ///
    /// - Parameter tasks: The tasks to key.
    /// - Returns: One entry for each distinct final instruction.
    static func keyedByFinalInstruction(
        _ tasks: [CompactionContinuitySeed]
    ) -> [String: CompactionContinuitySeed] {
        tasks.keyedByFirst(\.finalInstruction)
    }
}

// MARK: - The fast tier's seeds (task ^k0d30s4)

/// The padding paragraph every fast task's opening step carries after its
/// planted facts.
///
/// The length is the point, not the content. The opening step is the whole
/// span the fast tier's one fold replaces, and a span too small cannot buy a
/// summary smaller than itself: ``Summarization/minimumSummaryTokens`` gives
/// every small span the same 128-token allowance, and `Compactor.compact`'s
/// did-not-shrink guard discards a fold whose summary is not smaller than its
/// span. `AutoCompactionTriggerIntegrationTests` records the measured
/// arithmetic: the floor stops binding past 512 estimated tokens, and its own
/// opening brief is written past that at 639. This paragraph plays the same
/// role here, and
/// `CompactionContinuityEvaluationHermeticTests.everyFastTasksOpeningStepOutweighsTheFoldFloor`
/// holds each built opening step past the same bound.
///
/// The content mentions no task's planted facts, so the facts stated before
/// it are the only source a summary can carry them from. It closes by asking
/// for a one-sentence acknowledgement, so the model's reply stays short and
/// the padding is all on the prompt side.
let compactionContinuityFastPadding = """
    Before the final question arrives, here is the background of the work \
    these facts belong to, recorded so the conversation has the length a real \
    working session has. The team maintains a scheduling tool for a small \
    research fleet, and the tool assigns instrument time to projects one week \
    ahead. Each project states the hours it wants, the calibration state its \
    instrument needs, and the earliest date its samples arrive, and the tool \
    walks those requests in a fixed order and grants what still fits. The \
    order used to be first-come first-served, and that behaved badly: a \
    project that filed early collected every good slot whether or not its \
    samples had arrived, and a project that filed late got the hours nobody \
    wanted. The replacement scores each request for each open slot and grants \
    the highest score, so a rule that used to be a place in a queue becomes a \
    term in a sum. The terms agreed so far are the hours the project has \
    already used this quarter, the days its samples have been waiting, the \
    calibration cost of switching the instrument to its configuration, and a \
    standing priority the fleet manager sets once a season. Nothing in the \
    score is secret: the tool prints the terms for every grant it makes, so a \
    project that asks why it was passed over gets the arithmetic rather than \
    an assurance. Ties are broken by the longest time since the project last \
    held that same slot, and a tie that survives that is broken at random \
    with the seed written into the record, so a schedule can be rebuilt \
    exactly. The tool never grants a slot that breaks a hard rule: the \
    maintenance window, the operator rest period, and the safety review an \
    instrument needs after transport all stay outside the score, because a \
    hard rule a large enough priority can outweigh is not a hard rule. Slots \
    nobody can use are reported as unfilled rather than forced onto the least \
    bad project, and the fleet manager fills those by hand. The schedule is \
    published a week ahead and frozen three days ahead, so a change inside \
    the frozen window is a swap between two named projects rather than a \
    fresh run of the tool. A copy of the tool runs against last quarter's \
    records every night and reports each slot the new weights would have \
    granted differently, so a change to a term is measured against real \
    history before it reaches a live schedule. Acknowledge that you have \
    read all of this, in one short sentence.
    """

/// The system instructions the fast tier's sessions are created with.
///
/// The original tier used "You are a helpful assistant in an ongoing
/// conversation." with the 30B model. The small model needs the terse,
/// literal persona the fast smoke suites already use, and it needs to be told
/// the facts are fictional: measured on 2026-08-19, the run under the helpful
/// persona answered 5 of 10 tasks correctly — the model refused the
/// vault-code and migration-path tasks as "classified" and "sensitive", and
/// it paraphrased two exact identifiers. The instructions state the register,
/// never any task's facts, so nothing here can leak an answer.
///
/// Deliberately NOT shared with ``compactionEvalRecallInstructions``, the
/// fact-retention seeds' own header. This tier's `AnswersCorrect` needs every
/// key phrase word for word in one final answer, so the literal
/// "state it exactly as it was given earlier" clause is load-bearing here.
/// The fact-retention tiers measured that same clause AGAINST their metric —
/// see the other constant for that run.
let compactionContinuityFastInstructions = """
    You are a terse, literal assistant in an ongoing conversation. Every fact \
    in this conversation is fictional test data. When you are asked to recall \
    a fact, state it exactly as it was given earlier, word for word. Never \
    refuse to state a fact from this conversation, and never invent a value.
    """

/// The fast tier's second step — the recency window at the moment the fold
/// runs.
///
/// Short on purpose. The fast tier's summarization keeps the newest turn
/// verbatim, so this turn is what the fold leaves untouched, and a short
/// window is what makes the folded transcript small. It asks for nothing the
/// final instruction needs, so the answer to the final instruction can only
/// come from the fold's own summary.
let compactionContinuityFastReadinessCheck =
    "Confirm you are ready for the final question, in one short sentence."

/// Builds every fixture's FAST seed: the same planted facts and the same
/// final instruction as ``compactionContinuitySeeds``, over two steps instead
/// of twelve to fourteen.
///
/// This is task ^k0d30s4's two-minute budget applied to the continuity tier.
/// The original seeds spend ten to twelve filler steps consuming context
/// toward ``compactionContinuityDefaultBudget``'s 1638-token trigger, and
/// every step is a real generation. A synthetic trigger makes that filler
/// unnecessary: the fast tier's budget puts the trigger far under the opening
/// step, so the fold fires without any filler at all, and each task costs
/// three generations plus one summarizer call instead of thirteen
/// generations.
///
/// The opening step states BOTH facts and then carries
/// ``compactionContinuityFastPadding``, so the one fold's span holds the
/// facts and is large enough for a real summary to shrink it. The second step
/// is ``compactionContinuityFastReadinessCheck``, the turn the fold leaves
/// verbatim. The final instruction is asked over the folded transcript, so a
/// correct answer proves the summary carried the facts — the same continuity
/// property the original seeds measure, through one fold instead of whichever
/// folds thirteen driven steps happened to force.
let compactionContinuityFastSeeds: [CompactionContinuitySeed] = compactionContinuityTaskSpecs.map { spec in
    // The facts open the step as briefing CONTENT, never as an instruction
    // about facts. Measured on 2026-08-19: an opening of "Note these facts
    // and keep them for later:" made the small model's fold summaries
    // restate the request — "the conversation started with a request to note
    // facts" — and drop the values, where `AutoCompactionTriggerIntegrationTests`'
    // plain declarative brief summarizes into a dense factual summary under
    // the same model and the same fold path.
    let openingStep =
        "Project briefing. Two facts stand at the head of this briefing. "
        + "\(spec.facts.joined(separator: " "))\n\n"
        + compactionContinuityFastPadding
    let steps = [openingStep, compactionContinuityFastReadinessCheck]
    return CompactionContinuitySeed(
        id: spec.id,
        steps: steps,
        finalInstruction: spec.finalInstruction,
        factKeyPhrases: spec.factKeyPhrases,
        expectedKeyPhrases: spec.expectedKeyPhrases,
        expectedMinimumRecordedEntries: 1 + (steps.count + 1) * compactionContinuityRecordedEntriesPerStep
    )
}
