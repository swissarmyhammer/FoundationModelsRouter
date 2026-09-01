---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1cz6p61wvw8e9eyamx0j0dw
  text: |-
    ### The decision is made: choice 1, publish now

    The user decided on 2026-08-31 to publish now. Do not wait for ACPAgent
    to compile. Remove the `needs-decision` gate. The first acceptance
    criterion is satisfied.

    ### Three additions to the acceptance criteria

    ACPAgent supplied these on 2026-08-31. Each one lets the card pass its
    criteria and still leave ACPAgent unable to use the result. None of them
    changes the design.

    **1. The types behind the report properties must be public.**

    Swift does not permit a public property with an internal type. Thus
    `RestoredSession` cannot be public with `configurationReport` and
    `contextMismatches` unless these come with it:

    - `SessionConfigurationRestorationReport`
    - `SessionConfigurationRestorationReport.MissingTool`
    - `RestoredSessionTree.ContextMismatch`

    `ContextMismatch` is nested in `RestoredSessionTree`, which stays
    internal. Move it, or give it a new home. Do not make
    `RestoredSessionTree` public to reach it.

    The members of these types must be public also. `ContextMismatch` holds
    `session`, `recorded` and `resolved`, each marked
    `// periphery:ignore`. Examine those marks: a public property that a
    consumer reads is no longer invisible to periphery.

    Scope note: this card is not one method. Count the types.

    **2. A catchable error for "no such session".**

    `SessionTreeRestorationError` is internal. ACP `session/resume` on a
    deleted session must give a clean protocol error, and ACPAgent has an
    explicit criterion for it. With only `any Error`, ACPAgent cannot tell
    "this session is gone" from "restore failed for another reason", and
    must match on a message string.

    Do one of these:

    - Make `SessionTreeRestorationError` public.
    - Give one distinguishable public case for a missing or unreadable
      session.

    Note that a missing session throws `TranscriptTreeError.sessionNotFound`
    today, not `SessionTreeRestorationError`. Read the restore path before
    you choose. The consumer must be able to catch the real error that a
    missing session produces.

    **3. Decide how a caller reads the recorded working directory.**

    ACPAgent must compare the resume `cwd` with the recorded creation `cwd`,
    and refuse if they differ. It must not silently use a new root.

    There is no public way to read the recorded `cwd` before a restore.
    `SessionSidecar` publishes no stored property. `TranscriptEvent` does not
    hold a `cwd`.

    To restore first and then compare `restored.session.workingDirectory` is
    correct but reversed: the caller builds the full session, and then
    rejects it.

    Investigate and choose:

    - If a read-only accessor for the recorded working directory costs one
      property, add it.
    - If it costs more, document the after-the-fact comparison as the
      supported path.

    Record which you chose and why.

    ### Source

    Cross-session messages with `foundationmodelsacpagent-87`, 2026-08-31.
  timestamp: 2026-08-31T22:31:55.329737+00:00
- actor: claude-code
  id: 01m1da9efpznbnv6s86htkyhtn
  text: |
    ### The working-directory decision, and why

    **Chosen: add the accessor.** The new public method is
    `RoutedModel.recordedWorkingDirectory(ofSession:recordingRoot:)` in
    `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift`.

    The cost is one method with a three-line body. It calls the existing
    internal `transcriptTree(recordingRoot:)`, reads `node.sidecar.workingDirectory`,
    and returns it. It builds no backend and no session, and it writes nothing.
    It throws `TranscriptTreeError.sessionNotFound(_:)` for an unknown id, the
    same error `restoreSession` throws.

    The after-the-fact comparison was rejected for one reason: it is the wrong
    order. A caller that must refuse a resume in a new working directory would
    have to reassemble the whole session first, and then throw it away. That
    reassembly reads the session's transcript and every ancestor's, and it
    builds a live backend. The accessor makes the check cost one tree load.

    Publishing `SessionSidecar.workingDirectory` was rejected as the more
    expensive path. It would need `TranscriptTree` and `SessionNode`, both
    `package` today, to become public as well, so a caller could reach a
    sidecar at all. That is three types instead of one method.

    ### The instructions override reaches the root node alone

    `restoreSessionTree` restores a whole tree. The override applies only to
    the node named by `rootId`. A fork under that root keeps whatever its own
    sidecar recorded. `restoreSession(id:)` names a root, so the override
    always reaches the session the caller asked for.

    ### A discovery: the model's own view of the instructions

    The card states that "instructions are not in the transcript". That is
    true of the RESTORE construction — `container.makeSession(transcript:tools:)`
    takes no `instructions` argument — but it is not true of the recorded
    stream. `RoutedLLM.makeSession` says so in its own comment: "the first
    turn's whole transcript diff (including any leading `.instructions` entry)
    is new". So a live root session records an `.instructions` entry, and
    `effectiveTranscript` reconstructs it.

    What the override changes is `RoutedSessionActor.instructions`. A fork
    taken from the restored session inherits that value and writes it into its
    own sidecar. What the restored model reads at its next turn still comes
    from the reconstructed transcript.

    This is what the card asked for, word for word: the override replaces
    `node.sidecar.instructions` at the site the card names, and the divergence
    marker states the difference in the record. Making the restored backend
    see the new string as well is a separate change, and it needs its own
    decision, because it would rewrite a recorded entry rather than append.
    Raise a new card if ACPAgent needs it.

    ### The divergence marker

    The phrase is
    `restored session instructions differ from the recorded instructions`,
    declared once as `RestoredSession.instructionsDivergencePhrase`. The whole
    text is built by `RestoredSession.instructionsDivergenceText(recorded:supplied:)`
    and reads:

        restored session instructions differ from the recorded instructions: recorded 26 characters, supplied 46 characters

    No instructions body, no hash. A `nil` recorded string reads as a length
    of zero.

    The event is written through `routedLLM.recorder.append(_:to:)`, the same
    call `RecordingLanguageModel` uses for its own divergence marker. A
    `.divergence` event is not an entry kind, so it never enters
    `effectiveEntryEvents` and it moves neither `historyOrdinal` nor a fork's
    cut point.
  timestamp: 2026-09-01T01:45:40.086841+00:00
- actor: claude-code
  id: 01m1da9rca3mv03h0shrjy59wd
  text: |
    ### implement — changed
    - evidence: 6 files — `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift` (new), `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift`, `Sources/FoundationModelsRouter/Recording/TranscriptTree.swift`, `Sources/FoundationModelsRouter/Tracing/RouterTracing.swift`, `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift` (new), `Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift`.
    - public symbols added: `RoutedModel.restoreSession(id:recordingRoot:instructions:tools:)`, `RoutedModel.recordedWorkingDirectory(ofSession:recordingRoot:)`, `RestoredSession` with `session`/`configurationReport`/`contextMismatches`, `RestoredSession.ContextMismatch` with `session`/`recorded`/`resolved`, `SessionConfigurationRestorationReport` with `missingTools`/`isComplete`, `SessionConfigurationRestorationReport.MissingTool` with `session`/`toolName`, `SessionTreeRestorationError`, `TranscriptTreeError`.
    - internal, as the card requires: `restoreSessionTree(root:recordingRoot:instructions:tools:)` and `RestoredSessionTree`.
    - `swift test`: 1150 tests in 127 suites, plus 83 in 10 suites, exit 0, 2 known issues. The baseline was 1142 in 126 plus 83 in 10, so the run adds this card's 8 tests in 1 suite and moves nothing else.
    - `swift build --package-path IntegrationTests --build-tests`: Build complete, exit 0.
    - `swift build`: exit 0, no warning from any changed file.
    - next: `/review`.
  timestamp: 2026-09-01T01:45:50.218444+00:00
- actor: claude-code
  id: 01m1datq79fqhrq2g22e9tm5xf
  text: |
    ### review — findings

    - evidence: `review sha HEAD~1..HEAD`. The validator fleet reported 0 findings, 0 confirmed, 0 refuted, over 6 files. Two `.kanban` files were excluded by `.reviewignore`. The directed API verification of this pass added 4 findings: `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:93`, `:97`, `:48`, and `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:198`.
    - the gap is real: the supplied `instructions:` override does not change what the restored model reads. `SessionTreeRestoration.swift:352` calls `makeSession(transcript:tools:)`, which has no instructions argument. `LiveModelLoader.swift:51` builds the session from the transcript alone. `TranscriptEntryMapper.swift:139` replays the recorded `.instructions` entry into that transcript. The override changes `RoutedSessionActor.instructions` only, which feeds the sidecar and the forks.
    - the doc is not honest about the gap. The public parameter doc says the supplied string replaces the recorded one, and that the recorded instructions "were not the ones in force". Both claims are wrong for the model.
    - verified as correct: the internal tree walk, the `nil` path, the three tests, the `sessionNotFound` error, the working-directory accessor, and the removal of the `periphery:ignore` marks.
    - my own test run: `swift test` gave 1150 tests in 127 suites plus 83 in 10, exit 0, 2 known issues. `swift build --package-path IntegrationTests --build-tests` gave exit 0.
    - next: correct the four doc and record-text items, then run `/review` again. The task stays in `review`.
  timestamp: 2026-09-01T01:55:06.089619+00:00
- actor: claude-code
  id: 01m1davwc6bt47rz8vgsw3qyp3
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 6 files. The public surface matches the card exactly.
    - test: green — swift test, 1150 tests in 127 suites + 83 tests in 10 suites, exit 0
    - commit: d7ea4a9
    - review: findings — 4 open. Recording/SessionRestoration.swift:93, :97, :48; Recording/SessionTreeRestoration.swift:198.

    ### The orchestrator's own error, for the record

    The card says instructions are not in the transcript, so an override is only a
    constructor argument. I wrote that, and I gave it to the ACPAgent session as a
    measured fact. It is wrong.

    I read the path for a NEW session: `RoutedLLM.swift:154` calls
    `container.makeSession(instructions:tools:)`. The RESTORE path is different. It
    calls `container.makeSession(transcript:tools:)`, which has no `instructions`
    argument at all. `LiveModelLoader.swift:51` then builds the backend session from
    the transcript alone, and `TranscriptEntryMapper.swift:139` replays the recorded
    `.instructions` entry into it.

    So the override reaches `RoutedSessionActor.instructions` and stops. Three sites
    read that property, and no generation file is one of them. A caller's fresh
    instructions feed the sidecar and any later fork. They never reach the model.

    The feature as built is cosmetic for the use it was designed for.

    ### What to do

    Make it real. Do not document the limitation. A consumer asked for fresh
    instructions to take effect, the user approved that, and a doc comment that
    explains why the feature does not work is not the deliverable.

    The fix belongs in the reconstructed transcript: replace the `.instructions`
    entry with the override before the backend reads it.

    The three doc claims are findings only because the behaviour is wrong. Correct
    the behaviour, then the claims become true and need no hedging.
  timestamp: 2026-09-01T01:55:44.134002+00:00
- actor: claude-code
  id: 01m1db6d8v2vwatcrqgbrw7akc
  text: |
    ### Research for the second pass: where the transcript reaches the model

    I traced the restore path myself before writing code. The review's finding is
    correct, and the fix belongs in the reconstructed transcript.

    - `SessionTreeRestoration.rebuild(_:on:)` reads
      `tree.effectiveTranscript(forSession: node.id)` and hands that value to
      `routedLLM.container.makeSession(transcript:tools:)`.
    - `LoadedLLMContainer.makeSession(transcript:tools:)` has no `instructions`
      argument. `LiveModelLoader` builds
      `LanguageModelSession(model:tools:transcript:)` from the transcript alone.
    - The SDK reads the instructions from the leading `.instructions` entry.
      `TranscriptDiffer.leadingInstructionsText(of:)` names that same entry, and
      `RecordingLanguageModel.writeSidecarIfNeeded(transcript:)` writes the sidecar
      from it. So the sidecar string and the transcript entry are one fact.
    - `TranscriptEntryMapper.entry(from:kind:)` rebuilds that entry on the restore
      path, so the reconstructed transcript carries the recorded string.

    Thus the cleanest substitution point is the transcript itself, before
    `makeSession(transcript:tools:)` reads it. No new `makeSession` overload is
    needed, and the protocol stays as it is.

    ### The API the substitution uses

    `Transcript.Instructions(id:segments:toolDefinitions:)` is public, and its `id`
    defaults to a fresh UUID. So a helper can replace the leading entry in place,
    keeping its recorded id and its recorded tool definitions, or prepend a new
    entry when the recording holds none.

    ### Two invariants the substitution must keep

    - The recorded `transcript.jsonl` is not touched. The substitution builds a new
      in-memory `Transcript` value.
    - `persistedEntryCount` must count the transcript the backend really got. A
      prepended entry makes the seed one entry longer, and the count must include
      it, or the next turn's diff records that entry as new.
  timestamp: 2026-09-01T02:01:29.115516+00:00
- actor: claude-code
  id: 01m1dbr0nkkk632emk9bjvakqb
  text: |
    ### The fix, and how it was proved

    **The mechanism.** `TranscriptDiffer.replacingLeadingInstructions(of:with:)`
    returns a new `Transcript` whose leading `.instructions` entry carries the
    supplied text. It keeps that entry's recorded id and its recorded tool
    definitions, so entry identity survives and a later diff still matches it. A
    transcript that opens with another entry, or that is empty, gets a new leading
    `.instructions` entry.

    `restoreSessionTree` now calls a new nested function,
    `applyInstructionsOverride(to:transcript:on:)`. That function owns the whole
    override: it decides the node, it writes the divergence marker, and it returns
    both the instructions the actor holds and the transcript to seed the backend
    with. `rebuild(_:on:)` got shorter, not longer.

    **Two invariants the change keeps.**

    - `persistedEntryCount` now counts `seedTranscript`, not `transcript`. A
      prepended entry makes the seed one entry longer, and the next turn's diff
      must treat every entry of it as persisted. Without this the diff would
      record the substituted entry as new.
    - `historyOrdinal` still counts the raw effective entry events. The
      substitution does not touch recorded history.

    ### The failing-before result

    I wrote the two proving tests first and watched them fail on the committed
    code. `swift test --filter SessionRestorationTests`, 12 tests, 2 failures:

        ✘ "instructions that differ reach the transcript the restored backend is seeded from"
          SessionRestorationTests.swift:349: Expectation failed:
          TranscriptDiffer.leadingInstructionsText(of: seed) == Self.freshInstructions
            TranscriptDiffer.leadingInstructionsText(of: seed) → "be terse and cite the file"
            Self.freshInstructions → "be verbose, cite the file, and name the module"

        ✘ "instructions reach the seed transcript of a recording that holds no instructions entry"
          SessionRestorationTests.swift:371: Expectation failed:
          TranscriptDiffer.leadingInstructionsText(of: seed) == Self.freshInstructions
            TranscriptDiffer.leadingInstructionsText(of: seed) → nil
            Self.freshInstructions → "be verbose, cite the file, and name the module"

    The first failure shows the recorded string reaching the backend. The second
    shows nothing reaching it. After the fix all 12 pass.

    **What makes the test honest.** `SeedCapturingContainer` records every
    transcript handed to `makeSession(transcript:tools:)`. That is the exact seam
    the backend is built at, so the test reads what the model itself receives. A
    test that reads `RoutedSessionActor.instructions` is the test that let the
    first round through, and this suite now says so in its own header.

    Four tests were added, not two:

    1. an override reaches the seed transcript when the recording holds an
       `.instructions` entry;
    2. an override reaches the seed transcript when the recording holds none;
    3. `nil` leaves the recorded string in the seed transcript;
    4. an override leaves the recorded `.instructions` event on disk unchanged —
       one event, still carrying the recorded text.

    ### The fork decision: root only, and why

    The override reaches the node named by `rootId` and no other. Three reasons.

    1. A caller resumes by an id it holds, and it holds no id for a recorded fork.
       The card records this from ACPAgent.
    2. `restoreSession(id:)` rebuilds the recorded forks and then releases them.
       Nothing in the returned value names one, so their instructions are not
       observable through the public surface.
    3. A **live** fork taken later from the restored root does get the override,
       with no extra code. `RoutedSessionActorForking` passes `instructions`
       straight to the child, and `backend.makeFork(tools:)` seeds the child from
       the parent's live transcript, which now carries the substituted entry. So
       the two halves agree for every fork a caller can actually reach.

    A recorded fork keeps its own recorded string. That is what its own history
    says, and rewriting it would need its own decision.

    ### One discovery worth keeping

    The router writes a root session's sidecar from `RoutedSessionActor.instructions`
    directly, not from the transcript. So a stub container that ignores
    `instructions:` produces a recording whose sidecar names the instructions while
    the transcript holds no `.instructions` entry at all. Every earlier test in this
    suite used such a container. That is why `SeedCapturingContainer` takes
    `recordsInstructionsEntry`: `true` mirrors a live `LanguageModelSession`, and
    `false` is the genuine no-entry recording the card asked to keep working.
  timestamp: 2026-09-01T02:11:06.035707+00:00
- actor: claude-code
  id: 01m1dbre5r36fw5wmamsck0dbf
  text: |
    ### implement — changed
    - evidence: 4 files — `Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift`, `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift`, `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift`, `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift`.
    - the override now reaches the model: `TranscriptDiffer.replacingLeadingInstructions(of:with:)` substitutes the leading `.instructions` entry, and `applyInstructionsOverride(to:transcript:on:)` hands that transcript to `container.makeSession(transcript:tools:)`.
    - failing before the fix: `swift test --filter SessionRestorationTests` gave 12 tests with 2 failures. The seed transcript carried `"be terse and cite the file"` in one case and `nil` in the other, against the supplied `"be verbose, cite the file, and name the module"`. After the fix all 12 pass.
    - fork decision: root only. A recorded fork keeps its own recorded string, and `restoreSession(id:)` releases those forks. A live fork of the restored root inherits the override through both the backend transcript and `instructions`, with no extra code.
    - all four review findings are addressed and checked off. No public signature changed.
    - `swift test`: 1154 tests in 127 suites, plus 83 tests in 10 suites, exit 0, 2 known issues. The baseline was 1150 in 127 plus 83 in 10, so the run adds this pass's 4 tests and moves nothing else.
    - `swift build --package-path IntegrationTests --build-tests`: Build complete, exit 0.
    - `swift build`: exit 0, no warning from any changed file.
    - next: `/review`.
  timestamp: 2026-09-01T02:11:19.864758+00:00
- actor: claude-code
  id: 01m1dcnyw14ca7jjwz3wsh9v0a
  text: |-
    ### review — findings

    - scope: `review sha HEAD~1..HEAD`, which is commit `a8356cc` alone
    - engine: 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed
    - directed verification: 2 findings, both about tests that do not exist
    - evidence: `TranscriptDiffer.swift:186`, `SessionTreeRestoration.swift:450`
    - the central claim is true. The reviewer traced the override from
      `restoreSession` to `LanguageModelSession(model:tools:transcript:)` at
      `LiveModelLoader.swift:51`. The override reaches the model.
    - the red-test claim is true. The reviewer reverted the three source files
      to `a8356cc~1`, kept the tests, and ran them. Result: 12 tests, 2
      failures. Both failures are seed-transcript tests.
    - `swift test`: 1154 tests in 127 suites, plus 83 in 10 suites. Exit 0.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - next: add the two tests. Then run the review again.
  timestamp: 2026-09-01T02:27:27.233441+00:00
- actor: claude-code
  id: 01m1dcqderdgdb4mb0qssyfjex
  text: |-
    ### finish iteration 2 — findings
    - implement: changed — 4 files. The override now reaches the model.
    - test: green — swift test, 1154 tests in 127 suites + 83 tests in 10 suites, exit 0
    - commit: a8356cc
    - review: findings — 2 open. Recording/TranscriptDiffer.swift:186, Recording/SessionTreeRestoration.swift:450.

    The reviewer traced the path itself and confirmed the fix:
    `restoreSession` to `applyInstructionsOverride` to
    `replacingLeadingInstructions` to `makeSession(transcript:tools:)` to
    `LanguageModelSession(model:tools:transcript:)`. The SDK reads the
    instructions from that transcript, so the override arrives.

    The reviewer also proved the red test itself. It reverted the three source
    files in a throwaway worktree, kept the tests, and ran them: 12 tests, 2
    failures. The two failures read the seed transcript through
    `SeedCapturingContainer`, which is the correct seam.

    It ruled out one hazard nobody named: a substituted seed transcript could
    raise a false transcript divergence on the first turn. It does not, because
    the restore passes no `persistedBaseline`.

    Correction to the earlier record: this pass adds 4 tests, not 12. Twelve is
    the count of tests in the file. 1150 plus 4 is 1154.

    Both remaining findings are the same shape as the defect of round 1: a line
    that is correct today and that no test holds. Round 1 failed because a test
    read the wrong property. Add the guards.
  timestamp: 2026-09-01T02:28:14.936754+00:00
- actor: claude-code
  id: 01m1dd9cvqkh3343mha3y5eqac
  text: |
    ### Both findings are now guarded, and each guard was proved red

    Four tests were added to
    `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift`. No
    source behaviour changed. Each guarded line was broken, the test was run,
    and the line was put back.

    #### Finding 1 — `TranscriptDiffer.swift:186`

    The substitution keeps the recorded entry id and the recorded tool
    definitions. Two tests hold the two facts apart, because one test states
    one behaviour.

    - "an instructions override keeps the recorded entry id"
    - "an instructions override keeps the recorded tool definitions"

    Both read through `SeedCapturingContainer`, the seam the backend is built
    at, and both compare against the entry the recording holds on disk.

    The recorded entry must carry a real roster, or the tool-definition
    assertion would hold an empty list against an empty list.
    `SeedCapturingContainer` now takes `recordedToolDefinitions`, and the
    suite declares one `Transcript.ToolDefinition` named `search`. The test
    asserts the recorded payload carries that name before it asserts the
    substituted entry does.

    **Red proof A.** `toolDefinitions: recorded.toolDefinitions` was changed
    to `toolDefinitions: []`:

        ✘ "an instructions override keeps the recorded tool definitions"
          SessionRestorationTests.swift:594: Expectation failed:
          substitution.seeded.toolDefinitions.map(\.name) == [Self.recordedToolName]
            substitution.seeded.toolDefinitions.map(\.name) → []
            [Self.recordedToolName] → ["search"]

        SessionRestorationTests.swift:595: Expectation failed:
          substitution.seeded.toolDefinitions.map(\.description) == [Self.recordedToolDescription]
            substitution.seeded.toolDefinitions.map(\.description) → []
            [Self.recordedToolDescription] → ["search the recorded notes"]

    **Red proof B.** `id: recorded.id` was removed, so the entry took a fresh
    UUID:

        ✘ "an instructions override keeps the recorded entry id"
          SessionRestorationTests.swift:575: Expectation failed:
          substitution.seeded.id == substitution.recorded.entryId
            substitution.seeded.id → "8FFEAAE2-7668-42C7-B24B-29AA8A8BA15F"
            substitution.recorded.entryId → "A6B3EE7B-3CEE-4EA4-BB53-F0C803E0FF10"

    #### Finding 2 — `SessionTreeRestoration.swift:450`

    Two tests run a turn after a restore.

    - "a turn after a restore with an override records no instructions event"
      is the finding word for word. It restores a recording that holds no
      transcript entry at all, supplies an override, runs one turn, and
      asserts the recorded file gains no `.instructions` event.
    - "a turn after a restore with an override records only that turn's
      entries" is the general case. The recording holds one turn. After the
      restore and one more turn the recorded entry kinds must be exactly
      `[.prompt, .response, .prompt, .response]`.

    The second test is necessary. An undercount re-records the tail of the
    transcript, not its head, so a recording that already holds entries never
    gains an `.instructions` event from this break alone. The empty recording
    is the case where the head itself is re-recorded. The two tests together
    cover both.

    `recordRoot` takes `answersAPrompt: Bool = true` for the empty case. Every
    call that exists keeps its behaviour.

    **Red proof C.** `persistedEntryCount: seedTranscript.count` was changed
    to `persistedEntryCount: transcript.count`. Both tests failed:

        ✘ "a turn after a restore with an override records no instructions event"
          SessionRestorationTests.swift:623: Expectation failed: recorded.isEmpty
            recorded.isEmpty → false
            recorded → [TranscriptEvent(… kind: .instructions,
              text: Optional("be verbose, cite the file, and name the module") …)]

        ✘ "a turn after a restore with an override records only that turn's entries"
          SessionRestorationTests.swift:647: Expectation failed:
          kinds == [.prompt, .response, .prompt, .response]
            kinds → [.prompt, .response, .response, .prompt, .response]

    The first failure is the exact regression the card forbids: the override
    text entered the recorded `transcript.jsonl` as an `.instructions` event.

    #### The commands

    - `swift test`: 1158 tests in 127 suites, plus 83 tests in 10 suites. Exit
      0, 2 known issues. The baseline was 1154 plus 83, so the run adds this
      pass's 4 tests and moves nothing else.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `swift build`: exit 0.
    - `git status` shows one source-tree file changed: the test file. Both
      guarded lines are back at their committed text.
  timestamp: 2026-09-01T02:38:04.151861+00:00
- actor: claude-code
  id: 01m1ddkmp3cy37qm7m9q5snexd
  text: |
    ### Correction and final state: the tests were refactored, then proved red again

    The earlier comment reported line numbers from before a refactor. This comment
    replaces those numbers. It is the record to read.

    #### The refactor, and why

    I loaded the validator rules for `.swift` after writing the tests. The
    `duplication` validator is a blocker, and it states: "Two blocks that differ
    only by a value are one function with an argument." The two turn-after-restore
    tests differed by `answersAPrompt` and by their assertion. So the shared body
    moved into one helper:

        takeOneTurnAfterRestoring(cacheDir:recordingsDir:answersAPrompt:)

    Each test is now the temp-directory preamble, one call, and its own assertion.
    The finding-1 tests already shared
    `substituteInstructionsOnRestore(cacheDir:recordingsDir:)`, so they were not
    touched.

    #### The red proofs, re-run against the final file

    **Finding 1** — `TranscriptDiffer.swift:186`. The line was replaced by
    `Transcript.Instructions(segments: segments, toolDefinitions: [])`, which drops
    both the recorded id and the recorded roster:

        ✘ "an instructions override keeps the recorded tool definitions"
          SessionRestorationTests.swift:626: Expectation failed:
          substitution.seeded.toolDefinitions.map(\.name) == [Self.recordedToolName]
            substitution.seeded.toolDefinitions.map(\.name) → []
            [Self.recordedToolName] → ["search"]

          SessionRestorationTests.swift:627: Expectation failed:
          substitution.seeded.toolDefinitions.map(\.description) == [Self.recordedToolDescription]
            substitution.seeded.toolDefinitions.map(\.description) → []
            [Self.recordedToolDescription] → ["search the recorded notes"]

        ✘ "an instructions override keeps the recorded entry id"
          SessionRestorationTests.swift:607: Expectation failed:
          substitution.seeded.id == substitution.recorded.entryId
            substitution.seeded.id → "AA89CED5-FA2A-441E-AD91-F35AF0967FE2"
            substitution.recorded.entryId → "BFAE90C5-0270-4262-A31E-CD7DA400ADFF"

    An earlier pass also broke each half on its own, and each half failed on its own
    test alone.

    **Finding 2** — `SessionTreeRestoration.swift:450`. The line was changed to
    `persistedEntryCount: transcript.count`:

        ✘ "a turn after a restore with an override records no instructions event"
          SessionRestorationTests.swift:649: Expectation failed: recorded.isEmpty
            recorded.isEmpty → false
            recorded → [TranscriptEvent(… seq: 2, kind: .instructions,
              text: Optional("be verbose, cite the file, and name the module"),
              entry: Optional(TranscriptEntryPayload(entryId: "2CA19897-…") …))]

        ✘ "a turn after a restore with an override records only that turn's entries"
          SessionRestorationTests.swift:667: Expectation failed:
          kinds == [.prompt, .response, .prompt, .response]
            kinds → [.prompt, .response, .response, .prompt, .response]

    The first failure is the exact regression the card forbids: the override text
    reached the recorded `transcript.jsonl` as an `.instructions` event.

    #### One discovery worth keeping

    A root session that answers no prompt is still restorable. `RoutedSessionActor`
    writes the sidecar in its own `init`, and `TranscriptTree.load(under:)`
    discovers a session by its `session.json`. So the recording holds a session with
    no transcript entry at all, and its reconstructed transcript is empty. That is
    the only shape where an off-by-one on `persistedEntryCount` re-records the head
    of the transcript rather than its tail. It is why the finding's own assertion is
    falsifiable, and it is what `answersAPrompt: false` builds.

    #### Rule compliance the pass checked, item by item

    - `duplication`: resolved by the helper above.
    - `reuse`: the new tests call `recordRoot`, `recordedEvents`, and
      `SeedCapturingContainer`. `recordedEntryKinds` has one caller, which the rule
      permits and forbids inlining.
    - `test-integrity/no-test-cheating`: each test carries one failable `#expect`,
      and each was watched to fail.
    - `magic-numbers-swift`: a Swift Testing suite gets no exemption. The new code
      holds no numeric literal at all.
    - `missing-docs-swift`: it reads `open` and `public` only. Nothing new is
      public. Every new declaration still carries a doc comment.
    - `doc-parameter-naming`: every `- Parameter` entry names the internal name.
    - `access-control`: nothing narrowed, nothing published.
    - `function-length-swift`: the longest new declaration is far under 250 lines.
    - `test-partitioning`: unit target, stubs only, no environment variable. The
      suite runs in 0.08 seconds.

    #### The commands

    - `swift test`: 1158 tests in 127 suites, plus 83 tests in 10 suites. Exit 0,
      2 known issues. The baseline was 1154 plus 83.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `git diff -- Sources`: empty. Both guarded lines are back at their committed
      text.
  timestamp: 2026-09-01T02:43:39.843748+00:00
- actor: claude-code
  id: 01m1ddkwc4vwz3w3hwm234x5ej
  text: |
    ### implement — changed
    - evidence: 1 file — `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift`. No source file changed. `git diff -- Sources` is empty.
    - 4 tests added, and each was watched to fail. `TranscriptDiffer.swift:186` broken: `substitution.seeded.toolDefinitions.map(\.name) == [Self.recordedToolName]` gave `[]` against `["search"]`, and `substitution.seeded.id == substitution.recorded.entryId` gave a fresh UUID against the recorded id. `SessionTreeRestoration.swift:450` broken: `recorded.isEmpty` gave one `.instructions` event carrying the override text, and `kinds == [.prompt, .response, .prompt, .response]` gave `[.prompt, .response, .response, .prompt, .response]`.
    - both findings of 2026-08-31 21:13 are checked off in the description.
    - `swift test`: 1158 tests in 127 suites, plus 83 tests in 10 suites, exit 0, 2 known issues. The baseline was 1154 plus 83.
    - `swift build --package-path IntegrationTests --build-tests`: exit 0.
    - `swift build`: exit 0.
    - next: `/review`.
  timestamp: 2026-09-01T02:43:47.716086+00:00
- actor: claude-code
  id: 01m1de26zaxybay3rmbvp53314
  text: |-
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` on commit 35e679d. The engine found 0
      findings. It ran 7 validators and failed none. `git diff HEAD~1..HEAD --
      Sources` is empty, so this commit changes tests only.
    - red demonstration: the reviewer broke each guarded line and ran the tests.
      `TranscriptDiffer.swift:186` with `toolDefinitions: []` failed "an
      instructions override keeps the recorded tool definitions". The recorded-side
      assertion still passed, so the recording carries a real tool definition. The
      test cannot pass on two empty lists. The same line without `id: recorded.id`
      failed "an instructions override keeps the recorded entry id".
      `SessionTreeRestoration.swift:450` with `persistedEntryCount:
      transcript.count` failed both turn tests. The reviewer put every line back.
      `git status --porcelain` shows no change under `Sources`.
    - shared helper: `takeOneTurnAfterRestoring(cacheDir:recordingsDir:answersAPrompt:)`
      weakens neither test. Each test broke in its own case. The empty recording
      test caught the new instructions event. The non-empty test caught the
      re-recorded tail.
    - prior findings: all 6 stay fixed. The 4 doc findings of round 1 read true at
      `SessionRestoration.swift:48`, `:98` and `:106`, and at
      `SessionTreeRestoration.swift:185`. The 2 findings of round 2 are the tests
      this pass proved red.
    - fixture: `SeedCapturingContainer` now takes `recordedToolDefinitions`. The
      refactor changes no other test, because `StubSessionBackend(instructions:
      nil)` gives the same empty entry list as `StubSessionBackend()`.
    - commands: `swift test` gave 1158 tests in 127 suites and 83 tests in 10
      suites. All passed. The baseline was 1154, so this commit adds 4. `swift
      build --package-path IntegrationTests --build-tests`: exit 0.
    - next: none. The task moves to `done`.
  timestamp: 2026-09-01T02:51:37.322334+00:00
- actor: claude-code
  id: 01m1de33vp5jzqn3yns4e63s9q
  text: |-
    ### finish iteration 3 — clean
    - implement: changed — 1 test file. No source file changed.
    - test: green — swift test, 1158 tests in 127 suites + 83 tests in 10 suites, exit 0
    - commit: 35e679d
    - review: clean — 0 findings, 7 validators, 0 failed. Task moved to done.

    The reviewer reproduced every red demonstration itself. It broke each guarded
    line, ran the tests, and restored the line. It also proved the tool-definitions
    test cannot pass on two empty lists: under the broken line the recorded-side
    assertion still passed, so the recording carries one real definition.

    Card summary: 3 rounds, 6 findings, all fixed.

    Round 1 published the surface and the parameter. Round 2 found the parameter did
    not reach the model, so the feature was cosmetic. Round 3 guarded the two lines
    that hold the fix in place.

    The lesson worth keeping is the shape of the round-1 defect. The override set
    `RoutedSessionActor.instructions`, and the test read that same property. The
    test agreed with the code and both were wrong about the thing that matters. The
    correct seam is the transcript the backend is constructed with, and every test
    of this behaviour now reads it there.
  timestamp: 2026-09-01T02:52:06.902140+00:00
position_column: done
position_ordinal: ffffb180
title: 'Publish session restore for ACPAgent: one session by id, with an instructions override'
---
## The decision

A person selected choice 1, publish now, on 2026-08-31. See the comment
thread. The `needs-decision` gate is removed.

## The problem

`restoreSessionTree(root:recordingRoot:tools:)` is at
`Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:210`.
It is built, tested and correct, but it is `internal`.

It was `public` when written (`ef4985f`). Commit `fe5ce0e` made it
`internal` on 2026-08-26. That commit decreased the public surface from
812 declarations to 402. It removed `public` one folder at a time. Then
it built four consumers and put `public` back only where a build failed.
The four consumers were Router, Router IntegrationTests, Multitool and
Multitool IntegrationTests.

ACPAgent was not one of the four. A consumer that nobody builds cannot
fail a build. Thus the tool removed the symbols that ACPAgent needs, and
nobody saw it. This is the same cause as the five Multitool breaks of
2026-08-30.

## What ACPAgent needs

ACPAgent gave these answers on 2026-08-31.

**One session by id. Never a child.** The ACP `sessionId` is the ULID of
the root Router session. Thus `session/resume` can name only a root. A
client has no id for a fork, so it cannot ask for one. ACPAgent closes
the live tree, but those sessions are in the current process. They are
not restored sessions. Do not publish the tree walk.

**The mismatch report is necessary.** Resume is the point where the tool
roster differs from the recording. Examples: a config layer that now sets
`shell: false`; an MCP server that fails to connect; a deleted skill. A
transcript that names `tools.github.createIssue` when github did not
connect is a silent divergence. `MissingTool` is the fact that lets
ACPAgent report it.

**Tool attachment by recorded name is sufficient.** ACPAgent builds all
per-session state itself and supplies the instances through `tools:`.

## The defect this conferral found

The restored session keeps the recorded instructions. There is no
override:

    SessionTreeRestoration.swift:426
        instructions: node.sidecar.instructions,

The doc header at `:185` states this as intent: "`instructions`,
`Grammar`, and the recorded configuration envelope are re-applied."

ACPAgent assembles fresh instructions at resume from the config layer,
the AGENTS.md walk and the skill bodies. With the API as it is, ACPAgent
gives those instructions to nothing. The session then runs on the
recorded string. There is no error and no report. A person finds this
later as a model that obeys stale instructions.

## The design

    restoreSession(
        id: ULID,
        recordingRoot: URL? = nil,
        instructions: String? = nil,
        tools: [any Tool] = []
    ) async throws -> RestoredSession

`RestoredSession` holds `session`, `configurationReport` and
`contextMismatches`.

### Instructions behaviour

- `nil`: keep the recorded instructions. Write nothing to the journal.
- Supplied and equal to the recorded string: write nothing. No
  divergence occurred.
- Supplied and different: append one `divergence` event at restore.

### How the override reaches the model

The first round put the override on `RoutedSessionActor.instructions`
alone. That property feeds the sidecar and any later fork. It reaches no
generation path, so the model kept the recorded string.

The restore path builds its backend with
`container.makeSession(transcript:tools:)`, which takes no instructions
argument. `LiveModelLoader` then builds
`LanguageModelSession(model:tools:transcript:)`, and the SDK reads the
instructions from the transcript's leading `.instructions` entry.

So the override enters that entry.
`TranscriptDiffer.replacingLeadingInstructions(of:with:)` builds a new
in-memory transcript with the supplied text in that entry. It keeps the
entry's recorded id and its recorded tool definitions. A recording that
holds no `.instructions` entry gets a new leading one. The recorded
`transcript.jsonl` on disk is never rewritten.

### Why the journal and not the return value

ACPAgent made this argument, and it is correct. A caller that supplies a
value does not need a report that the value took effect. But that answer
serves the wrong reader.

The divergence that is important is between the transcript and the
session that ran. The recording says the model had instructions X. The
session runs with Y. ACPAgent commits transcripts to a repository. The
person who reads that file next month did not supply the argument. Today
nothing in the file tells that person that the recorded instructions were
not the instructions in force. The record is quietly incorrect about its
own conditions.

### The mechanism is already there

`TranscriptEvent.Kind.divergence` is at `TranscriptEvent.swift:37`. It is
router-only and `TranscriptEvent.text` holds the description. Two places
write it for this same purpose: `RoutedSessionActorRecording.swift:177`
and `RecordingLanguageModel.swift:350`. The fidelity tests call it "a
loud `.divergence` marker".

### Restore already writes

A journal write at restore is not a new class of operation. Restore makes
one terminal `.completed` event with outcome `.lost` for each orphaned
run. Thus the divergence event uses a write path that exists. It does not
make a read into a write.

### Event text

Use a stable phrase that a person can find with grep. Do not put either
instructions body in the event. Include the two lengths. Do not include a
hash: a reader cannot resolve a hash back to a string.

## Acceptance criteria

- [x] A person selects choice 1, 2 or 3, and the choice is recorded here.
- [x] `restoreSession(id:recordingRoot:instructions:tools:)` is public.
- [x] `RestoredSession` is public with `session`, `configurationReport`
      and `contextMismatches`.
- [x] `restoreSessionTree` and `RestoredSessionTree` stay internal. Do not
      publish the tree walk.
- [x] `instructions: nil` keeps the recorded instructions. This is the
      default, so all callers that exist keep their behaviour.
- [x] Supplied instructions that are equal to the recorded string write no
      event.
- [x] Supplied instructions that are different write exactly one
      `divergence` event. The text is stable and holds no instructions
      body.
- [x] Supplied instructions that are different reach the model, through
      the leading `.instructions` entry of the reconstructed transcript.
- [x] A test proves each of the three instructions cases.
- [x] A test proves the transcript the backend receives carries the
      override.
- [x] `swift build` and `swift test` are green.
- [x] `swift build --package-path IntegrationTests --build-tests` is
      green. Note: without `--build-tests` this command builds nothing.

### The three additions ACPAgent asked for

- [x] `SessionConfigurationRestorationReport`, its `MissingTool`, and
      `ContextMismatch` are public with public members. `ContextMismatch`
      moved out of `RestoredSessionTree` to `RestoredSession`, so the tree
      stays internal. The `// periphery:ignore` marks are gone, because
      `--retain-public` retains a public declaration.
- [x] A catchable error for "no such session". `TranscriptTreeError` is
      public, because `sessionNotFound` is what a missing session really
      raises. `SessionTreeRestorationError` is public beside it, so a
      caller can tell every other restore failure apart.
- [x] A read-only accessor for the recorded working directory:
      `recordedWorkingDirectory(ofSession:recordingRoot:)`. See the
      comment thread for the reasoning.

## Source

Cross-session messages with `foundationmodelsacpagent-87` on 2026-08-31.
The reasoning about the transcript reader is ACPAgent's, not a paraphrase. #api #router #recording

## Review Findings (2026-08-31 20:58)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 6 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

The validator fleet found nothing. The items below come from the directed
API verification of this pass. Each item is on a line this commit added.

- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:93` `api/doc-honesty` — The public doc says the supplied instructions "replace the recorded ones". The restored model still reads the recorded string. `SessionTreeRestoration.swift:352` calls `makeSession(transcript:tools:)`, which has no instructions argument. `LiveModelLoader.swift:51` builds `LanguageModelSession(model:tools:transcript:)` from the transcript alone. The rebuilt transcript keeps its leading `.instructions` entry (`TranscriptEntryMapper.swift:139`). State this limit in the parameter doc, or make the restore path give the override to the backend.
      **Resolved by the second option.** The restore path now gives the
      override to the backend. `applyInstructionsOverride(to:transcript:on:)`
      substitutes the leading `.instructions` entry through
      `TranscriptDiffer.replacingLeadingInstructions(of:with:)`, and
      `makeSession(transcript:tools:)` reads that substituted transcript.
      The parameter doc now states this.
- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:97` `api/doc-honesty` — The doc tells a transcript reader that "the recorded instructions were not the ones in force". The recorded instructions were in force for the model. Correct this sentence.
      **Resolved.** The sentence is now true, because the behaviour is
      fixed. The doc reads: "A later reader of that file then learns the
      session ran on instructions the file does not hold."
- [x] `Sources/FoundationModelsRouter/Recording/SessionRestoration.swift:48` `recording/record-accuracy` — The divergence phrase tells a future reader that the session ran on other instructions. The model ran on the recorded string. Make the phrase name what really changed: the session actor, its sidecar and its forks.
      **Resolved by correcting the behaviour, not the phrase.** The phrase
      is now accurate word for word, so it stays stable for grep. The doc
      above it states what the phrase covers: the session actor, the
      sidecar of any later fork, and the transcript the model reads.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:198` `api/doc-honesty` — The new `instructions` parameter doc promises a replacement on the root node. It does not say the backend keeps the recorded string. Add that limit here also. The commit message calls the gap "recorded in a comment", but no comment in this file records it.
      **Resolved.** There is no limit left to state. The parameter doc now
      says the override reaches the root's own backend, names the entry it
      replaces, and says the recorded `transcript.jsonl` is not rewritten.

### What the verification confirmed as correct

- The public surface matches the card. `restoreSessionTree` and
  `RestoredSessionTree` stay internal. Making `TranscriptTreeError` public
  dragged nothing else in. Its cases carry only `ULID` and `URL`.
- `instructions: nil` keeps the previous behaviour. `overrideForNode` is
  `nil`, so `effectiveInstructions` is `node.sidecar.instructions` and the
  write never runs.
- The three instructions cases each have a test that can fail. The
  equal-string test and the differing-string test form a matched pair.
- A missing session raises `TranscriptTreeError.sessionNotFound`. The test
  at `SessionRestorationTests.swift:295` proves it.
- `recordedWorkingDirectory` loads the tree only. It builds no backend and
  no session, and it writes nothing.
- The removed `// periphery:ignore` marks hide no dead code. Periphery has
  no config file in this repository and no CI step runs it.
- `swift build --package-path IntegrationTests --build-tests`: exit 0.

## Review Findings (2026-08-31 21:13)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

The validator fleet found nothing. The two items below come from the
directed verification of this pass. Each item is on a line this commit
added. The behaviour of each line is correct today. No test holds it.

- [x] `Sources/FoundationModelsRouter/Recording/TranscriptDiffer.swift:186` `tests/new-code-unguarded` — The substitution keeps the recorded entry id and the recorded tool definitions. No test asserts this. A later edit can drop `toolDefinitions`, and every test still passes. The restored session then loses its recorded tool declarations, and nothing reports it. Add a test. Restore a session with an override. Then assert the seed transcript's first entry keeps the recorded id and the recorded tool definitions.
      **Resolved.** Two tests hold the two facts apart, because one test
      states one behaviour: "an instructions override keeps the recorded
      entry id" and "an instructions override keeps the recorded tool
      definitions". Both restore under an override and read the seed
      transcript through `SeedCapturingContainer`. Both compare against the
      `.instructions` payload the recording holds on disk.
      `SeedCapturingContainer` now takes `recordedToolDefinitions`, so the
      recorded entry carries one real tool definition and the assertion
      cannot pass on two empty lists. Each half was proved red. Dropping
      `toolDefinitions` gave `[] == ["search"]`. Dropping `id: recorded.id`
      gave a fresh UUID against the recorded entry id. See the comment
      thread for both failures word for word.
- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:450` `tests/new-code-unguarded` — `persistedEntryCount: seedTranscript.count` stops the next turn's diff from recording a prepended entry. No test runs a turn after a restore, so no test holds this line. A later edit can write the override into the recorded `transcript.jsonl`. This breaks the rule this card states: the disk file stays as it is. Add a test. Restore a recording that holds no `.instructions` entry. Supply an override and run one turn. Then assert the recorded file gains no `.instructions` event.
      **Resolved.** Two tests run a turn after a restore. "a turn after a
      restore with an override records no instructions event" is this
      finding word for word. "a turn after a restore with an override
      records only that turn's entries" pins the whole recorded entry-kind
      sequence. The second test is necessary, because an undercount
      re-records the tail of the transcript rather than its head. A
      recording that already holds entries thus never gains an
      `.instructions` event from this break alone. The empty recording is
      the case where the head itself is re-recorded, and `recordRoot` takes
      `answersAPrompt: Bool = true` to build it. Both tests were proved
      red. `persistedEntryCount: transcript.count` wrote the override text
      into the recorded `transcript.jsonl` as an `.instructions` event.

### What this pass verified as correct

The reviewer traced the code. The reviewer did not accept the
implementer's word or the tests' word.

**The override reaches the model.** This is the trace:

1. `SessionRestoration.swift:118` — `restoreSession` calls `restoreSessionTree`.
2. `SessionTreeRestoration.swift:328` — `rebuild` calls `applyInstructionsOverride`.
3. `SessionTreeRestoration.swift:512` — the helper returns a seed transcript.
4. `TranscriptDiffer.swift:176` — the helper substitutes the leading entry.
5. `SessionTreeRestoration.swift:364` — `makeSession(transcript: seedTranscript, tools:)`.
6. `LiveModelLoader.swift:98` — the container calls `makeSessionBackend`.
7. `LiveModelLoader.swift:51` — `LanguageModelSession(model:tools:transcript:)`.

The SDK reads the instructions from that transcript. Thus the override
reaches the model. `LiveModelLoader.swift:55` also derives the backend's
own `instructions` from the same seed transcript.

**The recorded `transcript.jsonl` is not rewritten.**
`replacingLeadingInstructions` returns a new value. The restore writes
only the `.divergence` event.

**A recording with no `.instructions` entry works.** `recorded` is
optional. A supplied string never equals `nil`. Thus the guard falls
through, and `TranscriptDiffer.swift:181` prepends the entry.

**The entry id and the tool definitions survive.**
`TranscriptDiffer.swift:186` passes `recorded.id` and
`recorded.toolDefinitions`.

**`persistedEntryCount` counts the seed transcript.**
`RoutedSessionActorRecording.swift:184` builds `lastSeen` from
`entries.prefix(persistedEntryCount)`. The prefix covers the whole seed.
Thus the next diff reports no new entry.

**`historyOrdinal` stays correct.** The divergence write now happens
before `effectiveEntryEvents` reads the disk again.
`TranscriptEvent.swift:52` shows that `.divergence` is not an entry kind.
Thus the filter removes it, and the count does not change. The same
filter keeps a divergence event out of a later reconstructed transcript.

**`instructions: nil` keeps the previous behaviour.** The guard returns
the recorded string and the same transcript. A node that is not the root
gets the same result.

**The divergence event fires one time only.** `applyInstructionsOverride`
runs one time for each node. Only the root receives a non-nil override.
An equal string writes nothing.

**The first turn after a restore writes no false divergence.** The
restore passes no `persistedBaseline`. Thus
`RoutedSessionActorRecording.swift:167` skips the check.

**The three doc claims at `SessionRestoration.swift` are true.** Lines
100, 106 and 48 each agree with the code.

**The fork decision is root only.** `SessionTreeRestoration.swift:515`
compares `node.id` with `rootId`. `restoreSessionTree` refuses a node
that has a parent. The fork doc is true:
`RoutedSessionActorForking.swift:192` seeds the child from the parent's
live backend, and line 219 passes the parent's instructions.

**The red-test claim is true.** This pass reverted the three source files
to `a8356cc~1` and kept the tests at `a8356cc`. The run reported 12
tests and 2 failures. The two failures are the seed-transcript tests.
The tests read the seed transcript through `SeedCapturingContainer`, not
through `RoutedSessionActor.instructions`. The commit adds 4 tests.
"Twelve" is the count of tests in the file.

**The commands are green.** `swift test`: 1154 tests in 127 suites, and
83 tests in 10 suites. Exit 0, no failure and no skip. Two known issues
are old and are in tests that pass. `swift build --package-path
IntegrationTests --build-tests`: exit 0. Note: the working tree holds
uncommitted test files that this commit does not touch. They were
present during the run.