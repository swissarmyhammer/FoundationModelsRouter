import FoundationModels

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

/// A small, reused pool of filler turns padding every fixture's untouchable
/// recency window — content that pads the transcript but is never itself the
/// subject of a question, so its variety (or lack of it) does not affect
/// dataset diversity. Mirrors ``CompactionRoundTripIntegrationTests``'s own
/// convention of reusing a short trailing instruction across scripted turns.
let compactionEvalFillerTurns: [String] = [
    "By the way, what's a good one-word codename for a low-priority task?",
    "Quick check: does this conversation still make sense to you so far?",
    "Unrelated question: name any color that isn't blue.",
    "Just chatting — what's a common synonym for \"quick\"?",
    "Give me a one-word synonym for \"finished\".",
    "Say any short greeting.",
]

/// Every hand-written fixture (compaction_plan.md §5): 24 seed transcripts —
/// well over the required 20–30 — spanning single- and multi-fact heads,
/// plain-reply and tool-traffic delivery, and short-to-long overall lengths.
let compactionEvalFixtureSpecs: [CompactionEvalFixtureSpec] = [
    CompactionEvalFixtureSpec(
        id: "env-file",
        facts: ["The API key for this project lives in `.env.example`, never in a real `.env` file."],
        probedFactIndex: 0,
        factKeyPhrase: ".env.example",
        question: "Which file holds the API key for this project?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "tabs-vs-spaces",
        facts: ["The team chose tabs over spaces for indentation in this repository."],
        probedFactIndex: 0,
        factKeyPhrase: "tabs",
        question: "What indentation style did the team choose for this repository?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "vault-code",
        facts: ["The project's internal vault code is CRIMSON-77; it must be remembered precisely."],
        probedFactIndex: 0,
        factKeyPhrase: "CRIMSON-77",
        question: "What is the exact vault code for this project?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "db-port",
        facts: ["The staging database listens on port 6543, not the default 5432."],
        probedFactIndex: 0,
        factKeyPhrase: "6543",
        question: "What port does the staging database listen on?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "release-branch",
        facts: ["Releases are cut from the `release/stable` branch, never directly from `main`."],
        probedFactIndex: 0,
        factKeyPhrase: "release/stable",
        question: "Which branch are releases cut from?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "allergy",
        facts: ["The user is allergic to shellfish and must never be given a recipe containing it."],
        probedFactIndex: 0,
        factKeyPhrase: "shellfish",
        question: "What food allergy does the user have?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "flight-number",
        facts: ["The user's return flight number is BA-249, departing from gate 12."],
        probedFactIndex: 0,
        factKeyPhrase: "BA-249",
        question: "What is the user's return flight number?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "codename",
        facts: ["The internal codename for the new feature is \"Project Longbow\"."],
        probedFactIndex: 0,
        factKeyPhrase: "Longbow",
        question: "What is the internal codename for the new feature?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "license-key-and-region",
        facts: [
            "The license key for the analytics tool is stored in the team password manager under \"analytics-prod\".",
            "The production deployment region is eu-west-2, chosen for data-residency reasons.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "eu-west-2",
        question: "Which region is the production deployment in, and why was it chosen?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "meeting-time-and-reviewer",
        facts: [
            "The weekly sync moved from Tuesday to Thursday at 3pm.",
            "Every pull request against `main` needs sign-off from Priya before merging.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "Priya",
        question: "Whose sign-off is required before merging a pull request against main?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "pet-name-and-vet",
        facts: [
            "The user's cat is named Biscuit.",
            "Biscuit's vet appointment is booked for the 14th at the Riverside clinic.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "Riverside",
        question: "Where is Biscuit's vet appointment booked, and for which date?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "wifi-and-guest-policy",
        facts: [
            "The office wifi password is printed on the back of the router, not shared over chat.",
            "Guests must be signed in at the front desk before receiving the wifi password.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "router",
        question: "Where is the office wifi password printed, and is it ever shared over chat?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "recipe-substitution-and-timing",
        facts: [
            "In this recipe, butter can be substituted with coconut oil in equal measure.",
            "The dough needs to rest in the fridge for at least 45 minutes before baking.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "coconut oil",
        question: "What can butter be substituted with in this recipe, and in what ratio?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "budget-cap-tool-and-owner",
        facts: [
            "The monthly cloud spend cap for this project is $4,200.",
            "Any spend increase above the cap needs written approval from the finance owner, Marcus.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "4,200",
        question: "What is the monthly cloud spend cap for this project?",
        probedFactViaTool: true,
        recentTurnCount: 6
    ),
    CompactionEvalFixtureSpec(
        id: "server-hostname",
        facts: ["The internal staging server's hostname is `stg-node-07.internal`."],
        probedFactIndex: 0,
        factKeyPhrase: "stg-node-07",
        question: "What is the internal staging server's hostname?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "travel-itinerary-hotel",
        facts: ["The hotel reservation for the conference is under the name \"Aldergate Inn\", confirmation JH-3391."],
        probedFactIndex: 0,
        factKeyPhrase: "JH-3391",
        question: "What hotel is the conference reservation under, and what is the confirmation code?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-migration",
        facts: [
            "The database migration must run before the API deploy, never after.",
            "The migration script lives at `scripts/migrate_2026_07.sql`.",
            "A rollback script exists at `scripts/rollback_2026_07.sql` in case the migration fails.",
        ],
        probedFactIndex: 2,
        factKeyPhrase: "rollback_2026_07",
        question: "Where is the rollback script for the migration located?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-onboarding",
        facts: [
            "New hires get access to the design system Figma file on day one.",
            "New hires do not get production database access until after their second week.",
            "The onboarding buddy for new hires this quarter is Sana.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "second week",
        question: "When do new hires get production database access?",
        probedFactViaTool: false,
        recentTurnCount: 6
    ),
    CompactionEvalFixtureSpec(
        id: "game-strategy-and-seed",
        facts: [
            "In this playthrough, the party's healer should always act before the mage in turn order.",
            "The current dungeon seed is 8821, noted for a guaranteed rare drop on floor 3.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "8821",
        question: "What is the current dungeon seed, and what is it noted for?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "config-flag-and-owner",
        facts: [
            "The feature flag `enable-fast-path` must stay off in production until QA signs off.",
            "QA sign-off for `enable-fast-path` is owned by the platform team, not the feature team.",
        ],
        probedFactIndex: 1,
        factKeyPhrase: "platform team",
        question: "Which team owns QA sign-off for the `enable-fast-path` flag?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-support-escalation",
        facts: [
            "Tier-1 support tickets escalate to tier-2 after 2 hours with no response.",
            "Tier-2 support tickets escalate to the on-call engineer after 6 hours with no response.",
            "The on-call escalation contact this week is Dana, reachable via the pager rotation.",
        ],
        probedFactIndex: 0,
        factKeyPhrase: "2 hours",
        question: "After how long does a tier-1 support ticket escalate to tier-2?",
        probedFactViaTool: false,
        recentTurnCount: 7
    ),
    CompactionEvalFixtureSpec(
        id: "printer-and-supply-closet",
        facts: ["The office printer's spare toner cartridges are kept in the third-floor supply closet, not the mailroom."],
        probedFactIndex: 0,
        factKeyPhrase: "supply closet",
        question: "Where are the spare printer toner cartridges kept?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "encryption-algorithm",
        facts: ["Data at rest in this project is encrypted with AES-256-GCM, never the older CBC mode."],
        probedFactIndex: 0,
        factKeyPhrase: "AES-256-GCM",
        question: "Which encryption mode is used for data at rest in this project?",
        probedFactViaTool: true,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-long-project-brief",
        facts: [
            "This project catalogs nineteenth-century weather station logs from six remote outposts.",
            "Each outpost reports barometric pressure, wind direction, and temperature three times daily.",
            "The archive's internal reference id for this cataloging effort is WX-ARCHIVE-6.",
        ],
        probedFactIndex: 2,
        factKeyPhrase: "WX-ARCHIVE-6",
        question: "What is the internal reference id for this weather-archive cataloging effort?",
        probedFactViaTool: false,
        recentTurnCount: 6
    ),
]

/// Builds every fixture's ``CompactionEvalSeed``, keyed by
/// ``CompactionEvalFixtureSpec/id``. Computed once, lazily, and reused by
/// every ``CompactionEvaluation`` instance constructed in this target (each
/// points at the same dataset, differing only in the ``CompactionPrompt``
/// under test).
let compactionEvalSeeds: [CompactionEvalSeed] = compactionEvalFixtureSpecs.map(CompactionEvalSeed.build(from:))
