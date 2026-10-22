---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f81axnrt7enveabm59c94j
  text: |-
    Notes:
    - Name difference: the origin field is `FoundationModelsExtras.SessionDirectoryOrigin?` (EXTRAS-3's name), not `SessionOrigin`. SessionConfiguration now imports FoundationModelsExtras; the qualified spelling is kept beside `hookOrigin: SessionOrigin?` (Hooks).
    - New config fields go at the end of `SessionConfiguration.init`, all defaulted; `persistable` is unchanged. `SessionConfiguration.initialFacts` builds the first `SessionFacts`.
    - Thread: `makeSession(configuration:)` -> internal `makeSession(grammar:...facts:)` -> `makeRoutedSessionActor(... facts:)` -> actor init (`factsState: Mutex<SessionFacts>`). Both new params default to `SessionFacts()`, so the fork and restore sites are unchanged here (next ROUTER-1 card).
    - File write: `SessionSidecarOrigin.writeFactsIfNew(_:to:)` runs right after `writeSidecarIfNew` in the actor init; only `.new` origins whose writer is not `.off` write (`recordsFacts`). Failures log and drop through the shared `SessionSidecarWriter.logDroppedWrite`.
    - `updateFacts` (RoutedSessionActorFacts.swift) is `nonisolated`, holds the lock across the atomic write, swaps only after the write succeeds, and writes no file for a memory-only/off session.
    - Interim caveat for the next card: a fork currently writes an empty facts.json (fork = `.new` origin with default facts), and a restored session holds empty facts in memory; an `updateFacts` on a restored session today would replace its on-disk facts. Nothing calls `updateFacts` in production yet.
    - Existing test changed: `SessionSidecarTests.aRunWritesOnlySidecarsAndTranscripts` asserted each session directory holds only session.json and transcript.jsonl; it now also expects facts.json (the card puts facts.json beside session.json). No other existing assertion changed.
  timestamp: 2026-10-21T12:47:33.301822+00:00
- actor: claude-code
  id: 01m5f81dhtn38hdzckkd5e3k9t
  text: |-
    ### implement — changed
    - evidence: Sources: Session/SessionConfiguration.swift, RoutedLLM.swift, Session/RoutedSessionActor.swift, Session/RoutedSessionActorFacts.swift (new), Session/RoutedSession.swift, Recording/SessionSidecar.swift. Tests: SessionFactsRecordingTests.swift (5 tests, new), SessionSidecarTests.swift (one expectation widened to facts.json). RED: build failed (no `facts`, no `updateFacts`, no config fields). GREEN: `swift build --build-tests` clean (only the pre-existing "missing creator for mutated node" note); full `swift test`: 1955 tests / 244 suites passed with 9 known issues; 28 / 16; 19 / 3.
    - next: review
  timestamp: 2026-10-21T12:47:35.994977+00:00
- actor: claude-code
  id: 01m5g7w8nfknajrhvr4gb2dej7
  text: |-
    ### review — findings
    - evidence: review sha 11676c31~1..11676c31 — 1 finding (1 confirmed, 0 refuted): Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:1037 swift/initialization (line still present on HEAD)
    - next: implement — resolve the Review Findings (2026-10-21 16:59) checklist
  timestamp: 2026-10-21T22:04:01.583538+00:00
- actor: claude-code
  id: 01m5g7yb27ts2k8595hypkfgh7
  text: |-
    BLOCKER (true conflict, nothing changed). The finding `swift/initialization` at RoutedSessionActor.swift:1037 asks that a failed facts.json write reach the caller (factory `throws`, or a throwing init). The instruction was also to remove the same cause from the whole file and to add a test that a failed facts.json write fails the vend. Three documented contracts conflict with that:
    1. **The premise is wrong.** The sidecar write is not in the factory. `sidecarOrigin.writeSidecarIfNew(...)` also runs inside the non-throwing `RoutedSessionActor.init`, and `SessionSidecarWriter.write` logs and drops on failure (SessionSidecar.swift doc: "A failure is logged and the sidecar is dropped"). The "pattern at line 361" is that log-and-drop catch. It does not propagate anything. Removing the same cause from the whole file means the sidecar write has to propagate too.
    2. **An existing test pins best-effort failure.** `SessionSidecarTests.sessionWithUnwritableSidecarStillForksAndGenerates` ("a session whose sidecar can never be written still forks and generates normally": "Best-effort failure must never surface into `fork()`/`respond()`") makes the recordings root a regular file. With that root, the sidecar write and the facts.json write both fail. If a failed write fails the vend or the fork, this test breaks, and so does the contract it documents.
    3. **The public vend API cannot throw.** `RoutedModel.makeSession(...)` and `makeSession(configuration:)` are public and return `any RoutedSession` with no `throws`. There are hundreds of `makeSession()` call sites in Tests, plus downstream packages. To fail the vend, the public API must become `throws`. The card says the new fields are added "so no caller changes", so this is outside its scope.
    Choices for a person: (a) keep writes best-effort, move both the sidecar and facts writes out of `init` into `makeRoutedSessionActor`, and keep log-and-drop. The slow work leaves init, but no error propagates and there is no "fails the vend" test. (b) Make vend, fork and restore throw on a failed recording write, retire the best-effort contract and its test, and accept the public API break. (c) Refute the finding as fighting the documented best-effort recording contract.
  timestamp: 2026-10-21T22:05:09.575003+00:00
- actor: claude-code
  id: 01m5g7ydkw6ajfcktd5z56sdnn
  text: |-
    ### implement — stuck
    - evidence: no files changed. Conflict: finding swift/initialization (RoutedSessionActor.swift:1037) versus the documented best-effort recording contract. That contract is the SessionSidecarWriter doc, the SessionSidecarTests.sessionWithUnwritableSidecarStillForksAndGenerates test, and the non-throwing public RoutedModel.makeSession. The sidecar write that the fix was meant to copy is also in the non-throwing init and also logs and drops.
    - next: a person picks option (a), (b) or (c) from the blocker comment, then re-runs implement
  timestamp: 2026-10-21T22:05:12.188979+00:00
- actor: claude-code
  id: 01m5g7za5zz4kndswejexjtjqx
  text: |-
    ### finish iteration 1 — stuck
    - review (11676c31): findings — Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:1037 swift/initialization
    - implement: stuck — the finding conflicts with a documented contract: SessionSidecarWriter logs and drops a failed write by design, SessionSidecarTests.sessionWithUnwritableSidecarStillForksAndGenerates pins best-effort writes, and the public makeSession does not throw
    - needs a human decision: (a) move both writes into makeRoutedSessionActor and keep best-effort, (b) make vend/fork/restore throw (public API change), or (c) refute the finding
  timestamp: 2026-10-21T22:05:41.439883+00:00
- actor: claude-code
  id: 01m5hrx97ekm6whrt3b6z1fq0q
  text: |-
    ### decision (user, 2026-10-22)
    - Replace session.json + facts.json with one index.md per session folder: markdown with frontmatter holding the facts and the restore data, plus an open-ended body that Router keeps as-is. No backward compatibility, so no reader for the old pair (ARCHITECTURE.md, all packages).
    - Saves go through the Extras FrontmatterDocument save, which by default writes to a temp file and swaps it into place.
    - A failed save is logged and the session keeps working. That settles the RoutedSessionActor.swift:1037 finding as best-effort, with the write moved out of the initializer.
    - The rework gets its own cards; this card is superseded by them.
  timestamp: 2026-10-22T12:20:55.150940+00:00
- actor: wballard
  id: 01m5j2e39mcrzsq927f1yzq7av
  text: 'Archived: superseded by ^2cqepsd (index.md replaces session.json and facts.json; saves are best-effort and atomic), per the user''s decision 2026-10-22. Its open findings are about facts.json, which goes away.'
  timestamp: 2026-10-22T15:07:23.316904+00:00
depends_on:
- 01M5F3D4VMZDN4VPA8D2MY7ET8
position_column: review
position_ordinal: '8680'
title: 'ROUTER-1: SessionConfiguration carries the facts, a vend writes facts.json, and the session holds its facts'
---
## Goal
The first `facts.json` of each new session comes from its `SessionConfiguration`, and the live session holds its facts where synchronous code can read them and the directory can rewrite them (tags, title, archive). The restore and fork side is the next ROUTER-1 card.

## Spec
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-1-session-facts
- /Users/wballard/github/swissarmyhammer/FoundationModelsRouter/session.md section 5.1
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 13.3

## What
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/SessionConfiguration.swift`: add `agentID: String?`, `agentName: String?`, `tags: Set<String>`, `title: String?`, `startedBy: ULID?`, `origin: FoundationModelsExtras.SessionOrigin?` (qualified: `hookOrigin` already uses the Hooks `SessionOrigin`), each with a default in `init` so no caller changes. They are not in `persistable` (the sidecar stays as it is).
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/RoutedLLM.swift` (`makeSession(configuration:)` and the internal `makeSession(grammar:...)`): build the initial `SessionFacts` and pass them to `makeRoutedSessionActor`.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift`: the actor keeps its facts in a `Mutex<SessionFacts>` so they are readable with no `await` (the directory's synchronous `register` builds the `started` summary from them). It writes the first `facts.json` where the `SessionSidecarOrigin.new` sidecar is written (`Recording/SessionSidecar.swift`). An internal `updateFacts(_ change: (inout SessionFacts) -> Void) throws -> SessionFacts` rewrites the file atomically and then swaps the value.
- `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/RoutedSession.swift`: `nonisolated var facts: SessionFacts { get }`.
- The kind (root, subagent, fork) is not stored: it comes from `agentSpawn` and the fork link.

## Subtasks
- [ ] Failing test first: a session vended with agent id, tags, title, `startedBy` and origin writes `facts.json` with those values, and its `session.json` has no new key.
- [ ] Add the configuration fields and thread them through the vend path to the actor's first write.
- [ ] Add `nonisolated var facts` (Mutex-backed) on `RoutedSession`, readable from a synchronous context.
- [ ] Add the internal `updateFacts`; a change rewrites `facts.json`, updates `facts`, and leaves `session.json` unchanged.

## Acceptance Criteria
- [ ] A new session's `facts.json` equals the facts of its configuration; `session.json` decodes to the same `SessionSidecar` as before this change.
- [ ] `session.facts` is readable with no `await` and equals the file.
- [ ] After `updateFacts`, `facts.json` and `session.facts` hold the new value and `session.json` is byte-for-byte unchanged.
- [ ] Existing `SessionSidecarTests` still pass.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/SessionFactsRecordingTests.swift` with the scripted models of `Tests/FoundationModelsRouterTestSupport` and `Tests/FoundationModelsRouterTests/Helpers/RouterTestFixtures.swift`.
- [ ] `swift test --filter SessionFactsRecording` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #recording

## Review Findings (2026-10-21 16:59)

> Scope: `review sha 11676c31~1..11676c31` — reviewed the diffs only — lines this change added or modified. 8 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [ ] `Sources/FoundationModelsRouter/Session/RoutedSessionActor.swift:1037` `swift/initialization` — The initializer performs disk I/O (`sidecarOrigin.writeFactsIfNew`) which is slow work. The initializer is not `throws`, so it cannot report write failures to the caller; failures are instead silently logged. According to the initialization rule, slow work like disk I/O should happen in explicit methods the caller invokes (e.g., `load()`), not in `init`. Either (1) make the initializer `throws` to propagate write failures properly, or (2) move the facts write to the factory function `makeRoutedSessionActor` where explicit error handling is available, following the pattern of the sidecar write at line 361.
