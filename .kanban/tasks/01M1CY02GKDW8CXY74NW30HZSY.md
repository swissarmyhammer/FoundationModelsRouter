---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: 'Publish session restore for ACPAgent: one session by id, with an instructions override'
---
## Do not start this card yet

A person must first make the publish decision. See "The decision" below.

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

## The decision a person must make

ACPAgent has no code. The package is a plan, a board and a stub
`Package.swift` that builds an empty target. All answers above come from
numbered plan sections that are older than this conversation.

To do this card is to grow the public surface for a consumer that cannot
yet fail a build. That is the same judgement that made `fe5ce0e` remove
these symbols.

Three choices:

1. Publish now, on the strength of the plan.
2. Keep this card. Do the work when ACPAgent builds against the Router.
3. Do not publish. ACPAgent stays internal-only.

The design does not change between the three. Only the time changes.

## Acceptance criteria

- [ ] A person selects choice 1, 2 or 3, and the choice is recorded here.
- [ ] `restoreSession(id:recordingRoot:instructions:tools:)` is public.
- [ ] `RestoredSession` is public with `session`, `configurationReport`
      and `contextMismatches`.
- [ ] `restoreSessionTree` and `RestoredSessionTree` stay internal. Do not
      publish the tree walk.
- [ ] `instructions: nil` keeps the recorded instructions. This is the
      default, so all callers that exist keep their behaviour.
- [ ] Supplied instructions that are equal to the recorded string write no
      event.
- [ ] Supplied instructions that are different write exactly one
      `divergence` event. The text is stable and holds no instructions
      body.
- [ ] A test proves each of the three instructions cases.
- [ ] `swift build` and `swift test` are green.
- [ ] `swift build --package-path IntegrationTests --build-tests` is
      green. Note: without `--build-tests` this command builds nothing.

## Source

Cross-session messages with `foundationmodelsacpagent-87` on 2026-08-31.
The reasoning about the transcript reader is ACPAgent's, not a paraphrase. #api #router #recording #needs-decision