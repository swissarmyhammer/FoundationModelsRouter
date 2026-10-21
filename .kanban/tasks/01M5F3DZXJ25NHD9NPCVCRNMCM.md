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
depends_on:
- 01M5F3D4VMZDN4VPA8D2MY7ET8
position_column: review
position_ordinal: '8180'
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
