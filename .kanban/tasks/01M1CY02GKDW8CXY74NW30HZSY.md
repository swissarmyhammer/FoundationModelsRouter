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
position_column: doing
position_ordinal: '80'
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

An override is cheap, because instructions are not in the transcript:

- `TranscriptReconstruction.swift` writes no instructions entry.
- Instructions go to the backend as a constructor argument:
  `RoutedLLM.swift:154`,
  `container.makeSession(instructions:tools:)`.

Thus the recorded value is only the default argument.

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

A journal write at restore is not a new class of operation:

    SessionTreeRestoration.swift:404
        for lostEvent in TranscriptTree.lostRunTerminalEvents(in: effectiveEvents) {
            await outbox.post(event: lostEvent)
        }

The doc header at `:194` promises this. Restore makes one terminal
`.completed` event with outcome `.lost` for each orphaned run. Thus the
divergence event uses a write path that exists. It does not make a read
into a write.

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
- [x] A test proves each of the three instructions cases.
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