---
comments:
- actor: claude-code
  id: 01m2v8z0041e1n7p4jrf3aq5yj
  text: |-
    Research done. Findings:
    - `Compactor.stages` is a static list. `ToolOutputElision` and `TurnTruncation` have no rule input. `Summarization.apply` runs on the original transcript and folds all old turns.
    - The session flow: `SessionConfiguration` -> `RoutedModel.makeSession(configuration:)` -> internal `makeSession(grammar:...)` -> `makeRoutedSessionActor` -> `RoutedSessionActor` stored `nonisolated let`. Fork (`RoutedSessionActorForking`) and restore (`restoreSessionTree`) pass each value again. The frozen public `makeSession(instructions:...)` convenience (^pckk91c) must not change.
    - The rule is a closure, thus it cannot go in `SessionConfiguration.Persistable`. The restore must get it from the host, the same as `tools`. Plan: add a defaulted `toolOutputProtection:` parameter to `restoreSession(id:...)` and `restoreSessionTree(root:...)`.
    - `ToolCallOutputPairing.completedToolCallId` is the one pairing rule from a `.toolOutput` to its call. Use it per turn.
    - Recording: a fold records only the new entry ids (`TranscriptDiffer.diffByEntryId`). Restore resolves `liveWindowEntryIds` to the recorded events by id. Thus a protected entry that keeps its id and its content, and that is in the live window, restores word for word.
    - Design: a protected exchange = the `.toolCalls` entry with a protected call, plus every `.toolOutput` that answers that entry (a non-protected one is elided). TurnTruncation and Summarization move the protected exchanges of the dropped turns into the kept part, after the header (and after the summary entry). The next split puts them in the header, thus a later fold does not touch them again.
  timestamp: 2026-09-18T22:07:32.868932+00:00
- actor: claude-code
  id: 01m2v9sy3pg4r97kmrqedanemq
  text: |-
    Implementation landed (TDD: stage tests and session tests were written first and failed to compile, because the API did not exist; then the code made them pass).

    Public names:
    - `public typealias ToolOutputProtection = @Sendable (_ call: Transcript.ToolCall, _ output: Transcript.ToolOutput) -> Bool` (Compaction/ToolOutputProtection.swift).
    - `SessionConfiguration.toolOutputProtection: ToolOutputProtection?` (default nil; not in `Persistable`).
    - `RoutedModel.makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:toolOutputProtection:)` (new trailing parameter, default nil).
    - `RoutedModel.restoreSession(id:recordingRoot:instructions:tools:toolOutputProtection:)` (new trailing parameter, default nil).
    - `CompactionResult.protectedTokens: Int` (default 0).

    Mechanics:
    - `ProtectedToolOutputs` pairs each `.toolOutput` with its call through `ToolCallOutputPairing.completedToolCallId` (by id first), with the scope reset at each `.prompt`.
    - `ToolOutputElision` keeps a protected output unchanged. `TurnTruncation` keeps, right after the header and in original order, the `.toolCalls` entry reduced to its protected calls (new id `<id>-protected` only when a call is removed, so the fold records it and a restore rebuilds it) plus the protected output. `Summarization` does the same (kept pair before the summary entry), sends no protected output to the summarizer, charges the kept bytes out of the span budget, and names the kept ids in `liveWindowEntryIds`.
    - `Compactor.compact(..., protection:)`: when only the protected outputs keep a deterministic fold over target (protected alone over target, or the fold is under target without them), the fold completes anyway, `protectedTokens` reports it, and a warning is logged. No loop.
    - Fork passes the rule; `restoreSessionTree(..., toolOutputProtection:)` passes it to every node.

    Discovery: two `GeneratedContent` parses of one JSON object with two keys compared unequal in one test run of two; the fixture uses a one-key argument object.
  timestamp: 2026-09-18T22:22:15.670217+00:00
- actor: claude-code
  id: 01m2va2tq8pb4w8xy0p6q1r459
  text: |-
    ### implement — changed
    - evidence: `swift test` exit 0 — 1342 tests in 143 suites passed (2 known issues that existed before: BoundedWait, RealModelHarness embedding slot), plus 1 and 83 tests in the other products; the one build warning is the vendored mlx-swift "missing creator" warning. `swift build --package-path IntegrationTests --build-tests` builds. New tests: Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift (13), Tests/FoundationModelsRouterTests/ToolOutputProtectionSessionTests.swift (6). New code: Sources/FoundationModelsRouter/Compaction/ToolOutputProtection.swift. Changed: Compactor.swift, ToolOutputElision.swift, TurnTruncation.swift, Summarization.swift, SessionConfiguration.swift, RoutedLLM.swift, RoutedSessionActor.swift, RoutedSessionActorCompaction.swift, RoutedSessionActorForking.swift, SessionRestoration.swift, SessionTreeRestoration.swift, GuidedGeneration.swift (comment), plus DocC link updates for the new signatures in 27 files. New task for a stale link that existed before: "A test doc comment names a restoreSessionTree signature that does not exist".
    - next: /review
  timestamp: 2026-09-18T22:27:07.112933+00:00
- actor: claude-code
  id: 01m2va9vcb2v055b1evq5tq6jh
  text: |-
    ### test — green
    - Command: `swift build`. Result: 0 errors, 1 warning. The warning comes from the mlx-swift dependency, not from our code. The warning text is: "missing creator for mutated node" for the mlx-swift_Cmlx.bundle.
    - Command: `swift test`. Result: 1342 tests in 143 suites passed in 5.070 seconds. The run also shows 2 known issues. These known issues are not defects. They come from a test in BoundedWaitTests.swift. This test checks that BoundedWait records an issue when a wait condition does not become true. This is the correct, planned behavior.
    - Command: `swift test` also ran 1 test in 1 suite. That test passed.
    - Command: `swift test` also ran 83 tests in 10 suites. All 83 tests passed.
    - Total result: 0 failed tests, 0 skipped tests.
    - Command: `swift build --package-path IntegrationTests --build-tests`. Result: 0 errors. The build shows the same mlx-swift warning only.
    - Check: the test files do not contain `.disabled(`, `XCTSkip`, or `.skip(`. No test is turned off.
    - Next step: send this task for review.
  timestamp: 2026-09-18T22:30:57.163891+00:00
position_column: doing
position_ordinal: '80'
title: A host cannot keep a tool output through compaction, so a loaded skill is elided
---
## What

A host cannot keep a tool output through compaction. `FoundationModelsACPAgent` needs to keep the body of each skill that the model loads with the `skills` tool (`op: "use skill"`). That body is the procedure that the model must follow for the rest of the session.

Router has no seam for this:

- `Compactor.stages` is a fixed internal list: `[ToolOutputElision(), TurnTruncation()]` (`Compaction/Compactor.swift:90`).
- `ToolOutputElision` replaces the segments of every `.toolOutput` entry older than the recency window with `[elided: original "<tool>" output omitted by compaction]` (`Compaction/ToolOutputElision.swift`). It has no exemption.
- A host gives only `TokenBudget`, `CompactionPrompt` and `Summarization` to a session. None of them can mark an entry as protected.

Thus the first deterministic stage removes a loaded skill, and the model continues with no procedure and no visible error.

The Agent Skills standard says: "Skill instructions are durable behavioral guidance — losing them mid-conversation silently degrades the agent's performance without any visible error." It recommends that a host exempts skill content from pruning. Source: https://agentskills.io/client-implementation/adding-skills-support

## The work

1. A host-supplied rule that marks a tool output as protected. For example, a `SessionConfiguration` value such as `protectedToolOutput: @Sendable (Transcript.ToolOutput, Transcript.ToolCall?) -> Bool`, which gets the output and the call that made it (the host needs the arguments to see `op: "use skill"`). Choose the shape; it must be `Sendable`, and it must not need a tag in the output text.
2. `ToolOutputElision` keeps a protected output unchanged.
3. `TurnTruncation` and the summarization stage keep a protected output: a turn that holds one is not dropped whole, or the protected output moves into the kept part of the transcript. The summary never replaces it.
4. The rule is inherited by a fork, as the other session configuration is.
5. The recording and the restore of a session keep the protected entries unchanged.
6. Tests: a scripted session with a protected tool output and a tool output that is not protected; after a compaction that runs each stage, the protected output is in the transcript word for word, and the other one is elided.

## Host requirements

These come from the host that needs this card (`FoundationModelsACPAgent`). Obey them in addition to "The work".

1. Rule shape (suggested; the implementer chooses the final one): `public typealias ToolOutputProtection = @Sendable (_ call: Transcript.ToolCall, _ output: Transcript.ToolOutput) -> Bool`. The rule must see the CALL (the host decides on tool name "skills" and argument `op` == "use skill"). Pair the call and the output by id: the `.toolCalls` entry holds the call whose id is the id of the `.toolOutput` entry.
2. The rule is an optional field of `SessionConfiguration` (default nil = the behavior of today). Add a parameter with default nil to the `makeSession(instructions:workingDirectory:recordingRoot:tools:budget:compactionPrompt:)` overload on the standard profile, and to `restoreSession(id:recordingRoot:instructions:tools:...)`. The closure is not Codable, so it is not recorded: the host gives it again at restore, as it gives the tools. A fork inherits it.
3. Every stage keeps a protected output word for word:
   - `ToolOutputElision` does not elide it.
   - `TurnTruncation` must not lose it when it drops a turn. Keep the protected call and its output as a pair in the kept transcript: put the `.toolCalls` entry (reduced to the protected calls only) and the `.toolOutput` entry right after the header, in their original order. A `.toolOutput` must never stay without its call.
   - Summarization never replaces a protected output with summary text.
4. Protected outputs count against the budget like other entries. When protected content alone is over the target, do not remove it: complete the compaction with the other entries, and report it (for example in `CompactionResult`, or a log line). Do not loop.
5. No tag, marker or wrapper in the output text. Only the rule finds the entry.
6. Tests: a scripted session with one protected and one unprotected tool output, compacted through each stage, keeps the protected one word for word and elides the other; a fork keeps the rule; a restore with the rule keeps it.

If the Router code makes one of these points impossible, stop and report the exact conflict as `stuck`, with a proposal. Do not choose a different design.

## Where it was found

`FoundationModelsACPAgent`, card `^2zb9s07`. That card waits for this one. #compaction #cross-repo