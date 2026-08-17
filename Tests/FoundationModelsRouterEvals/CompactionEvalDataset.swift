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

    /// Background prose on this fixture's own subject, stated as the first
    /// turn of the foldable head, ahead of every fact turn.
    ///
    /// The fold has to be worth applying, and that is arithmetic rather than
    /// taste. `Compactor.compact` discards a fold whose summary entry is no
    /// smaller than the span it replaces, and
    /// ``Summarization/minimumSummaryTokens`` gives every span this small the
    /// same summary allowance — a floor of 128 tokens, which a real model
    /// spends on roughly 627 bytes of prose. A head of one fact sentence plus
    /// its acknowledgement is a few hundred bytes, so the fold cost more than
    /// it saved and the gated run of 2026-08-17 discarded 8 of 9 of them. This
    /// paragraph is what carries the head past that floor;
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

/// Every hand-written fixture (compaction_plan.md §5): 24 seed transcripts —
/// well over the required 20–30 — spanning single- and multi-fact heads,
/// plain-reply and tool-traffic delivery, and short-to-long overall lengths.
let compactionEvalFixtureSpecs: [CompactionEvalFixtureSpec] = [
    CompactionEvalFixtureSpec(
        id: "env-file",
        context: """
            Background for this session: the service reads its whole configuration from environment
            variables at startup, and the deployment scripts assemble those variables from three layers. The
            base defaults are checked into the repository, the per-environment overrides are held by the
            deployment tool, and a small set of secrets is injected by the platform at run time. The layers
            merge in that order, so a value set in the defaults can be replaced per environment and replaced
            again at run time, and a value that appears in none of the three is a startup failure rather
            than a silent empty string. Developers running the service on their own machines get the first
            two layers from the repository and are expected to supply the third themselves, which is the
            step new joiners most often miss. The merge is done by a short shell script rather than by the
            service, so the service sees one flat set of variables and cannot tell which layer any value
            came from. A long-standing request to make that script print the origin of each value has never
            been picked up. One service still reads a value the script no longer sets, and it falls back to
            a compiled-in default rather than failing, which is how the mismatch went unnoticed for a month.
            Reply with one short sentence acknowledging this.
            """,
        facts: ["The API key for this project lives in `.env.example`, never in a real `.env` file."],
        probedFactIndex: 0,
        factKeyPhrase: ".env.example",
        question: "Which file holds the API key for this project?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "tabs-vs-spaces",
        context: """
            Background for this session: the repository formats every source file with one shared
            configuration, checked in beside the code, and a commit hook rejects a file the formatter would
            change. The configuration fixes the line width at one hundred and twenty columns, forbids
            trailing whitespace, and requires a newline at the end of every file. It says nothing about the
            order of imports, which is the one thing reviewers still argue about, and nothing about comment
            wrapping, which the formatter leaves alone entirely. The hook runs only on the files a commit
            touches, so a change to the configuration itself does not reformat the whole tree; that is done
            deliberately, in one commit of its own, so the history stays readable afterwards. Generated
            sources are excluded by a list of paths rather than by a marker comment, because two of the
            generators write no header at all. The team reviews that exclusion list once a quarter and has
            removed two entries from it so far. Two long-lived branches were rebased onto the formatting
            commit rather than merged across it, because a merge across a whole-tree reformat produces
            conflicts in every file it touches and resolves none of them usefully. Reply with one short
            sentence acknowledging this.
            """,
        facts: ["The team chose tabs over spaces for indentation in this repository."],
        probedFactIndex: 0,
        factKeyPhrase: "tabs",
        question: "What indentation style did the team choose for this repository?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "vault-code",
        context: """
            Background for this session: every credential this project needs is held in one managed store,
            and nothing is read from a file on disk. Each service reads the store at startup with a
            short-lived token the platform mints for it, and the token is refreshed on a timer well before
            it expires, so a service that runs for weeks never has to be restarted for a credential alone.
            Access is granted per service rather than per person, and a person who needs to read a value
            does it through a command that records who asked and why. Values rotate on a fixed schedule, and
            a rotation writes the new value beside the old one for a grace period, so a service that has not
            refreshed yet keeps working. The store keeps a full audit trail, which is the reason nothing is
            copied out of it into a ticket or a chat message. Two values are exempt from rotation because
            the systems behind them cannot accept a new value without downtime, and both are tracked as open
            work. A separate copy of the store runs for the staging environment, holding values that look
            like the production ones but are not, so a service pointed at the wrong environment fails to
            authenticate rather than reading live data. Reply with one short sentence acknowledging this.
            """,
        facts: ["The project's internal vault code is CRIMSON-77; it must be remembered precisely."],
        probedFactIndex: 0,
        factKeyPhrase: "CRIMSON-77",
        question: "What is the exact vault code for this project?",
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
        question: "What port does the staging database listen on?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "release-branch",
        context: """
            Background for this session: the project ships on a two-week cadence, and every shipped build
            carries a tag naming the version it was cut at. The changelog is assembled from the commit
            subjects between two tags, so a commit whose subject says nothing useful shows up in the notes
            exactly as written, which is why the subject line is reviewed as carefully as the code. A
            release build is produced once and promoted through the environments unchanged; nothing is
            rebuilt for production, because a rebuild would not be the artifact that was tested. A fix that
            cannot wait for the next cadence is applied on top of the tag it fixes and shipped as a patch
            version, and the same fix is carried forward separately rather than merged backwards. The
            release itself is done by whoever is on the rotation that week, following a written checklist,
            and the checklist is updated in the same change as any process that alters it. Anything that
            changes the database is released separately from the code that depends on it, at least one
            cadence earlier, so a rollback of the code never has to be paired with a rollback of the schema.
            Reply with one short sentence acknowledging this.
            """,
        facts: ["Releases are cut from the `release/stable` branch, never directly from `main`."],
        probedFactIndex: 0,
        factKeyPhrase: "release/stable",
        question: "Which branch are releases cut from?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "allergy",
        context: """
            Background for this session: the user is planning a week of meals for a household of four,
            cooking on weekday evenings and once at the weekend, with leftovers expected to cover two
            lunches. The kitchen is small, with one oven and two working burners, so a plan that needs three
            pans going at once is not practical however good it reads. Shopping happens once a week, on
            Saturday morning, at one supermarket rather than a specialist grocer, so ingredients that need a
            special trip are out of scope unless the recipe is worth the trip on its own. The household
            prefers meals that reheat well, since the second serving is eaten a day or two later rather than
            the same evening. Two of the four eat very little red meat by preference rather than by rule.
            The user is happy to cook something new but wants the shopping list to stay under about twenty
            items in total across the whole week. One member of the household eats at a different time on
            Wednesdays, so that evening's meal has to hold for an hour without spoiling or has to be
            something that reheats in a single portion. Reply with one short sentence acknowledging this.
            """,
        facts: ["The user is allergic to shellfish and must never be given a recipe containing it."],
        probedFactIndex: 0,
        factKeyPhrase: "shellfish",
        question: "What food allergy does the user have?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "flight-number",
        context: """
            Background for this session: the user is travelling for a week-long conference and is booking
            the trip in pieces rather than as a package, so the flights, the hotel and the ground transport
            are each held separately. The outbound leg is already booked and leaves early enough that the
            user plans to stay near the airport the night before rather than risk the morning traffic. The
            return leg matters more than the outbound one, because a meeting is scheduled for the following
            morning and a delay would cost that meeting rather than an evening. Checked baggage is being
            avoided entirely, so everything has to fit in one cabin bag within the carrier's size limit. The
            user holds no status with the carrier and is not paying for a seat selection, so a middle seat
            is a real possibility on both legs. Travel insurance is bought through the user's own provider
            rather than the carrier's, and it requires the booking references to be filed within a week of
            purchase. The carrier changed its cabin bag policy this year and now weighs bags at the gate on
            the busier routes, so the user is packing to the weight limit rather than to the size limit
            alone. Reply with one short sentence acknowledging this.
            """,
        facts: ["The user's return flight number is BA-249, departing from gate 12."],
        probedFactIndex: 0,
        factKeyPhrase: "BA-249",
        question: "What is the user's return flight number?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "codename",
        context: """
            Background for this session: the new feature has been in design for about a month and is now
            moving into build, with a small team of three and a target of a first internal demo before the
            end of the quarter. The feature is being built behind a flag from the first commit, so it can
            ship dark and be turned on for a handful of internal accounts before anyone outside sees it. The
            design work produced two documents, one describing what the feature does and one describing what
            it deliberately does not do, and the second has been the more useful of the two in review.
            Nothing about the work is public yet, and the marketing team has not been briefed, so anything
            written down about it stays in the internal tracker rather than in a public issue. The team has
            agreed that the first release covers a single workflow end to end rather than several workflows
            partially, because a half-finished second workflow is worse than an absent one. A second team
            owns the surface the feature plugs into and has asked for two weeks of notice before anything
            lands there, which is the constraint that actually decides the demo date. Reply with one short
            sentence acknowledging this.
            """,
        facts: ["The internal codename for the new feature is \"Project Longbow\"."],
        probedFactIndex: 0,
        factKeyPhrase: "Longbow",
        question: "What is the internal codename for the new feature?",
        probedFactViaTool: false,
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
        question: "Which region is the production deployment in, and why was it chosen?",
        probedFactViaTool: false,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "meeting-time-and-reviewer",
        context: """
            Background for this session: the team works asynchronously most of the week and keeps exactly
            one recurring meeting, which exists to surface blockers rather than to give status, since status
            is written down where anyone can read it. The agenda is built from whatever people add to a
            shared document before the meeting starts, and an empty agenda means the meeting is cancelled
            rather than filled. Decisions taken in the meeting are written back into the tracker the same
            day, because a decision that lives only in someone's memory is a decision that will be
            relitigated. Code review is expected to happen within a working day, and a review that will take
            longer than that is expected to say so rather than sit silently. Nobody merges their own work
            without a second pair of eyes, however small the change, and the team has held that line even
            for one-line fixes because the exceptions were where the incidents came from. Reviews are
            assigned rather than volunteered, on a rotation that spreads the load, because the volunteer
            model left the same two people doing most of the reviewing and everyone else out of practice.
            Reply with one short sentence acknowledging this.
            """,
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
        context: """
            Background for this session: the user adopted an adult cat about eighteen months ago, from a
            shelter that had taken her in as a stray, so nothing is known about the first few years of her
            life. She is indoor-only, with access to a covered balcony, and she has settled well apart from
            a strong dislike of the carrier, which makes any trip out of the flat a planned event rather
            than a spontaneous one. Her weight was slightly high at the last check and the plan since then
            has been measured meals twice a day rather than a full bowl left out, which has worked. She is
            microchipped and the registration details were updated when the user moved last spring. Her
            vaccinations are up to date and were given at the shelter's own clinic before the adoption, so
            the records had to be transferred rather than started fresh. She has never needed treatment for
            anything beyond a mild ear infection in her first winter. She is due for her annual check and a
            dental assessment, and the dental part is new: the last visit noted some tartar and suggested it
            be looked at properly within the year. Reply with one short sentence acknowledging this.
            """,
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
        context: """
            Background for this session: the office network is split into two, with staff devices on one
            segment and everything else on another, and the two cannot reach each other at all. Printers,
            meeting-room displays and the door system sit on the second segment, which is why a laptop that
            has joined the wrong network can print but cannot reach the file server. The wireless coverage
            was surveyed when the floor was fitted out, and there are four access points, one of which is
            behind a fire door and is noticeably weaker than the other three. There is no wired networking
            at the desks, so a device that cannot join the wireless network cannot get online at all. The
            office manager keeps a written record of which devices are permanently on the second segment,
            and adding one is a request rather than something a person does themselves. A rolling password
            change happens twice a year, announced a week in advance. Visitors are common, several a week,
            and the current arrangement puts them on the same segment as the printers, which the office
            manager has flagged as something to revisit. Reply with one short sentence acknowledging this.
            """,
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
        context: """
            Background for this session: the recipe under discussion is a batch of shortbread-style
            biscuits, scaled to about thirty pieces, and it is being adapted for a bake sale rather than for
            a household. That changes a few things: the biscuits have to survive a few hours in a box
            without going soft, they have to be recognisable enough that a buyer knows what they are, and
            every ingredient has to be listed on a card beside the tray. The recipe as written uses very few
            ingredients, which is why each one carries a lot of weight and a careless substitution is
            obvious in the result. The baker has one domestic oven and two trays, so the batch is baked in
            three rounds and the last round waits at room temperature while the first two bake. Weighing is
            done on a digital scale rather than by cup measures, because the dough is sensitive to the ratio
            and volume measures vary too much between people. The sale is outdoors and the forecast is warm,
            which rules out anything that softens above room temperature and is part of why this recipe was
            chosen over the other candidate. Reply with one short sentence acknowledging this.
            """,
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
        question: "What is the monthly cloud spend cap for this project?",
        probedFactViaTool: true,
        recentTurnCount: 6
    ),
    CompactionEvalFixtureSpec(
        id: "server-hostname",
        context: """
            Background for this session: the staging environment is deliberately small, one machine for the
            application and one for the database, and it is rebuilt from configuration rather than patched
            in place, so a machine that drifts is replaced rather than repaired. Names are assigned from a
            scheme that encodes the environment and the role, and the scheme is documented in the runbook,
            which is where anyone looking for a machine starts. Access is through a bastion host with
            per-person keys, and no shared account exists on any machine. Logs are shipped off the machines
            as they are written, so nothing important is lost when a machine is replaced, and the shipped
            copy is what people actually read. Monitoring watches the application rather than the machine,
            on the reasoning that a machine at full memory serving traffic correctly is not an incident. The
            environment is rebuilt from scratch about once a month, deliberately, to prove that the rebuild
            still works. There is exactly one machine of each role, so there is no load balancer in front of
            anything, and a rebuild is therefore a short outage of the environment rather than a rolling
            change. Reply with one short sentence acknowledging this.
            """,
        facts: ["The internal staging server's hostname is `stg-node-07.internal`."],
        probedFactIndex: 0,
        factKeyPhrase: "stg-node-07",
        question: "What is the internal staging server's hostname?",
        probedFactViaTool: true,
        recentTurnCount: 4
    ),
    CompactionEvalFixtureSpec(
        id: "travel-itinerary-hotel",
        context: """
            Background for this session: the conference runs over four days and the user is attending all of
            it, arriving the evening before the first session and leaving the morning after the last. The
            venue is a short walk from the main station, and the user would rather walk than deal with
            taxis, which is the main thing shaping where to stay. Breakfast is not included at most of the
            nearby options, and the user is content with that because the conference provides it on three of
            the four mornings. The trip is being expensed, so every receipt has to be kept and the total has
            to stay within a stated daily limit, which rules out the two venues attached to the conference
            centre itself. The user is travelling alone but sharing a dinner with colleagues on the second
            evening, booked separately. A quiet room matters more than a large one, because the user plans
            to work in the room for an hour each evening. Check-in on the arrival evening will be late,
            after nine, so anywhere with a staffed desk only until eight has been ruled out however
            convenient it otherwise looked. Reply with one short sentence acknowledging this.
            """,
        facts: ["The hotel reservation for the conference is under the name \"Aldergate Inn\", confirmation JH-3391."],
        probedFactIndex: 0,
        factKeyPhrase: "JH-3391",
        question: "What hotel is the conference reservation under, and what is the confirmation code?",
        probedFactViaTool: false,
        recentTurnCount: 5
    ),
    CompactionEvalFixtureSpec(
        id: "three-facts-migration",
        context: """
            Background for this session: the release under discussion changes a table that every request
            touches, so the order of operations matters more than usual and the team has written the steps
            down rather than trusting anyone to remember them. The change is being done in two releases
            rather than one: the first adds the new column and writes to both, and the second stops writing
            the old one once the backfill has finished and been checked. That shape means the application
            has to tolerate both states, which is more code in the short term and far less risk. The
            backfill runs in batches with a pause between them so it does not starve live traffic, and it
            can be stopped and resumed without losing its place. The whole sequence has been rehearsed
            against a copy of production data, and the rehearsal is where the batch size was chosen, because
            the first guess was four times too large. The new column is nullable for the whole of the first
            release and is made required only after the backfill is verified, because a required column with
            a default rewrites the table on some engines. Reply with one short sentence acknowledging this.
            """,
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
        context: """
            Background for this session: the team hires in small numbers and treats the first fortnight as
            structured rather than improvised, with a written plan that the new joiner owns and edits as
            they go. The plan front-loads reading and pairing rather than tickets, on the reasoning that a
            person who understands why the system is shaped the way it is will pick up the work quickly,
            while a person handed a ticket on day one learns one corner and nothing else. Every new joiner
            ships something small to production in their first few days, deliberately, so the release path
            is familiar before it matters. Accounts and access are requested ahead of the start date rather
            than on it, because two of the systems take days to approve. The plan is reviewed at the end of
            the fortnight and edited for the next person, so it improves with each hire rather than aging
            quietly in a folder somewhere. Pairing is scheduled rather than left to chance, one session a
            day for the first week, and the partner rotates so the new joiner meets most of the team rather
            than one person repeatedly. Reply with one short sentence acknowledging this.
            """,
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
        context: """
            Background for this session: the playthrough under discussion is a four-character party on the
            harder of the two difficulty settings, where enemy damage is high enough that a single badly
            ordered round can end a fight. The party has settled into a shape after about twenty hours: one
            character absorbs damage, one heals and cleanses, one deals damage at range and one handles the
            utility abilities that open shortcuts and disarm traps. Consumables are plentiful and the party
            has stopped hoarding them, which was the main thing holding the run back earlier. Equipment
            upgrades come mostly from crafting rather than from drops, and the crafting materials are the
            real bottleneck. Save points are frequent enough that a lost fight costs a few minutes rather
            than an hour, so the run is being played fairly aggressively. The user is not following a guide
            and would rather work things out than be told the optimal answer. The party has skipped most of
            the optional content so far and is now going back for it, which is why the current area is well
            below the party level and the fights are short. Reply with one short sentence acknowledging
            this.
            """,
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
        context: """
            Background for this session: every behavioural change in this service ships behind a flag, and
            the flags are held in one service rather than in configuration files, so a flag can be turned on
            and off without a deploy. A flag is expected to be short-lived: it exists to separate the deploy
            from the release, and once a behaviour is on everywhere and has been for a while, the flag and
            the old code path are deleted together. A flag that has been at one value for more than a
            quarter is reported automatically, and the report is reviewed rather than ignored. Flags default
            to off, and a flag whose lookup fails returns the default rather than throwing, so an outage of
            the flag service degrades to the old behaviour instead of an error. Each flag records who
            created it and what it is for, because a flag with no owner is one nobody dares to remove and
            one nobody remembers. The flag service is read through a client that caches for a few seconds,
            so a change takes effect quickly but not instantly, and anything that needs an instant change is
            not a flag. Reply with one short sentence acknowledging this.
            """,
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
        question: "After how long does a tier-1 support ticket escalate to tier-2?",
        probedFactViaTool: false,
        recentTurnCount: 7
    ),
    CompactionEvalFixtureSpec(
        id: "printer-and-supply-closet",
        context: """
            Background for this session: the office occupies two floors of a shared building, with the
            shared facilities split between them rather than duplicated, so almost everything is a short
            walk away rather than on the same floor. The building's own post arrives once a day and is
            sorted by the front desk. There is one multifunction device for the whole office, on the third
            floor near the meeting rooms, and it handles printing, scanning and copying for both floors. It
            is set up to hold a job until the person who sent it releases it at the panel, which was
            introduced after too many uncollected pages piled up on the tray. Scanning goes to email rather
            than to a shared folder. Consumables are ordered monthly against a standing list, and anything
            used up between orders is raised with the office manager rather than bought ad hoc, which keeps
            the spend predictable and the deliveries to one a month. The device is on a service contract
            that covers parts and labour but not consumables, and a callout takes two working days, which is
            the reason a spare of everything is kept on site. Reply with one short sentence acknowledging
            this.
            """,
        facts: ["The office printer's spare toner cartridges are kept in the third-floor supply closet, not the mailroom."],
        probedFactIndex: 0,
        factKeyPhrase: "supply closet",
        question: "Where are the spare printer toner cartridges kept?",
        probedFactViaTool: false,
        recentTurnCount: 4
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

/// The fixtures the DEFAULT gated tier measures — a representative subset of
/// ``compactionEvalFixtureSpecs``, not its first few.
///
/// Every seed costs two real generations, one summarizer call inside the fold
/// and one answering turn on the resumed session, so the whole dataset does not
/// fit a wall-clock limit anyone runs by habit. `FM_ROUTER_INTEGRATION_TESTS=1`
/// therefore measures these seeds, and the whole dataset moves behind the second
/// opt-in variable `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` (task ^fz49qds).
///
/// What that costs is stated plainly: `factRetention >= 0.9` is measured over
/// this subset by default, and the whole-dataset number comes only from the
/// opt-in run.
///
/// Chosen for coverage. The dataset varies four things — how many facts the
/// foldable head states, which of them the question probes, whether the probed
/// fact arrives as tool traffic or as a plain reply, and how many filler turns
/// pad the untouchable recency window. Each member is here for a property it
/// carries, and together they span all four:
///
/// | fixture | head | probed fact | delivery | recency window |
/// |---|---|---|---|---|
/// | `env-file` | one fact | the only one | plain reply | 4 — the dataset's shortest |
/// | `db-port` | one fact | the only one | tool traffic | 4 |
/// | `encryption-algorithm` | one fact | the only one | tool traffic | 5 |
/// | `license-key-and-region` | two facts | the second, so the last of its head | plain reply | 4 |
/// | `budget-cap-tool-and-owner` | two facts | the first, so a fact the summary must reach past its sibling for | tool traffic | 6 |
/// | `three-facts-support-escalation` | three facts | the first of three | plain reply | 7 — the dataset's longest |
/// | `three-facts-long-project-brief` | three facts | the third, so the last of its head | plain reply | 6 |
///
/// `CompactionEvalRepresentativeSubsetTests` holds that coverage mechanically,
/// against the whole dataset rather than against this list, so a fixture that
/// widens the dataset widens what this subset must carry.
let compactionEvalRepresentativeSubsetIDs: [String] = [
    "env-file",
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
/// of specs, so a subset member is the same seed the full tier folds and the two
/// tiers can never measure two different transcripts under one fixture id.
let compactionEvalRepresentativeSeeds: [CompactionEvalSeed] = compactionEvalSeeds.filter {
    compactionEvalRepresentativeSubsetIDs.contains($0.id)
}
