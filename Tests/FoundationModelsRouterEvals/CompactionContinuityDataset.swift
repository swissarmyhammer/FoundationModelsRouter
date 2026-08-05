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
let compactionContinuityFillerSteps: [String] = [
    "By the way, what's a good one-word codename for a low-priority task?",
    "Quick check: does this conversation still make sense to you so far?",
    "Unrelated question: name any color that isn't blue.",
    "Just chatting — what's a common synonym for \"quick\"?",
    "Give me a one-word synonym for \"finished\".",
    "Say any short greeting.",
]

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
        fillerStepCount: 10,
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
        fillerStepCount: 10,
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
        fillerStepCount: 12,
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
        fillerStepCount: 10,
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
        fillerStepCount: 11,
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
        fillerStepCount: 10,
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
        fillerStepCount: 12,
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
        fillerStepCount: 11,
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
        fillerStepCount: 10,
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
        fillerStepCount: 12,
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
            expectedMinimumRecordedEntries: 1 + totalStepCount * 2
        )
    }
}
