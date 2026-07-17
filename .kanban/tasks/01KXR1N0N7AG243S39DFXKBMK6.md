---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kxr973a22v7bde8q11bn5zgm
  text: |-
    Implemented. Introduced `SessionSidecarOrigin` (enum: `.new(writer)` / `.restored(writer)` / `.memoryOnly`) in SessionSidecar.swift. `RoutedSessionActor.init` now takes `sidecarOrigin` instead of `sessionSidecarWriter: SessionSidecarWriter?` and lands the session's own write-once sidecar at construction via `writeSidecarIfNew` (root: no cut point; fork: cut point == persistedEntryCount, one fact). Removed the separate pre-write calls from `makeSession` and `fork`, from restoration (now `.restored`, read-only), and from both integration harnesses. A root actor built anywhere now cannot come into existence without its `session.json`, so the last nil-writer hole is closed by construction on the actor path.

    TDD: added SessionSidecarTests.aDirectlyBuiltRootSessionActorWritesItsOwnSidecar — a hand-built root actor with NO sidecar call by its builder must land its own. Watched it fail RED (read → nil), then GREEN. Mutation-checked: disabling the init write reddens both the new test AND theSidecarExistsBeforeTheFirstTranscriptEvent, as the card required.

    swift build clean; swift test 361/361 + 15/15 green. Note: the 4 FM_ROUTER_INTEGRATION_TESTS suites SKIP locally, so the two integration-harness edits are verified only by compilation, not execution — reasoned correct below.

    Scope note: RecordingLanguageModel (the resuming *handle*, not the actor) still carries `sessionSidecarWriter: SessionSidecarWriter?` and lazily writes via its own `didWriteSidecar` guard. That is a distinct type outside this card's stated scope (RoutedSessionActor); left untouched.
  timestamp: 2026-07-17T14:55:45.986864+00:00
- actor: claude-code
  id: 01kxrahr5j5g7t75fach1gsj95
  text: 'Review finding fixed. Added a symmetric `static func restored(under durableRecording: DurableRecording?) -> SessionSidecarOrigin` factory to SessionSidecarOrigin in Sources/FoundationModelsRouter/Recording/SessionSidecar.swift, mirroring the existing `new(under:)` factory (same signature/body/doc shape). Replaced the inline `.map { .restored($0.sidecarWriter) } ?? .memoryOnly` at the single call site in SessionTreeRestoration.swift with `SessionSidecarOrigin.restored(under: routedLLM.durableRecording)`. Grep confirmed no other inline `.map { .restored/.new(...) } ?? .memoryOnly` shapes remain — the two factory bodies are the only occurrences. swift build green; swift test 361 passed, integration suites skipped (FM_ROUTER_INTEGRATION_TESTS unset). double-check agent returned PASS. Left in doing for review.'
  timestamp: 2026-07-17T15:19:03.602094+00:00
position_column: doing
position_ordinal: '80'
title: Make a root session's sidecar the actor's own responsibility, closing the last nil-writer hole
---
Follow-up from ^zta2q14's review, raised by its adversarial double-check. Not urgent: no known live defect, and every in-repo caller is correct today. This closes the last place the sidecar invariant is upheld by convention rather than by the type.

**Where it stands after ^zta2q14.** That card paired `RoutedModel`'s durable root and its sidecar writer into one `DurableRecording`, so "durable root + no writer" is unrepresentable *on the handle*, and — the part that caused the reported bug — it can no longer arise from silence, since both halves used to default to `nil`.

**What it did not fix.** `RoutedSessionActor` still takes `sessionSidecarWriter: SessionSidecarWriter?` as a bare optional, and — more to the point — a **root's** sidecar write is not the actor's job at all. `fork()` writes its child's sidecar itself (correctly, inside the actor, with the cut point in hand), but a root's sidecar is written by `RoutedModel.makeSession` *before* constructing the actor. Any other caller that builds a root actor directly must remember to make that same call. Two test harnesses do exactly that today, and are correct only because a comment tells the next author to keep them so:

- Tests/FoundationModelsRouterIntegrationTests/TranscriptReconstructionIntegrationTests.swift
- Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift

Both hand-build a root actor because they need the `MLXFoundationModelsSessionBackend` object itself (to compare a reconstruction against the live `session.transcript`), which `makeSession()` does not vend. So the exact shape ^zta2q14's findings flagged — a durable session directory holding a `transcript.jsonl` with no `session.json` beside it, which `TranscriptTree.load` refuses — remains constructible on this path.

**Suggested direction** (from the review; confirm before building). Make the root's sidecar write happen at `RoutedSessionActor` init, mirroring what `fork()` already does for children: a session writes its own facts when it comes into existence, whoever built it. Then `makeSession`'s separate pre-write disappears, the two harnesses' hand-typed `write(...)` calls disappear, and "a session directory always has a sidecar" holds by construction on every path rather than on four callers' discipline.

**Watch out for** — the reasons this wasn't just done inline:
- Ordering is load-bearing and already proved: `SessionSidecarTests.theSidecarExistsBeforeTheFirstTranscriptEvent` asserts the sidecar is on disk at the instant of each session's first append. Whatever moves must keep that true, and that test must stay the thing that proves it (it is mutation-checked: deferring the root's write off the vending path reddens it).
- `makeSession` currently does this write inline, on the caller's thread, deliberately — see its doc comment. That "facts on disk before any transcript, by construction rather than by an awaited handshake" property is the whole point and must survive.
- A root has no cut point (`forkedAtEntryCount: nil`) and carries the run's resolved-profile facts; a fork is the inverse. That rule lives in one place today (`SessionSidecarWriter.write`: no cut point == root). Keep it there.
- The seam that makes the harnesses hand-build actors at all is the absence of a way to vend a session *and* reach its backend. If that seam is worth adding, the harnesses could use the public surface instead and the whole class of bug goes away — possibly the better fix, and worth weighing first.

**Acceptance**: a root actor constructed directly, with no separate sidecar call by its builder, still lands its `session.json` before any transcript event; the two harnesses drop their hand-typed root-sidecar writes; `theSidecarExistsBeforeTheFirstTranscriptEvent` still passes and still reddens under mutation; full suite green.

## Review Findings (2026-07-17 10:03)

- [x] `Sources/FoundationModelsRouter/Recording/SessionTreeRestoration.swift:166` — The pattern `durableRecording.map { .restored($0.sidecarWriter) } ?? .memoryOnly` reimplements what `SessionSidecarOrigin.new(under:)` already does, just for the `.restored` case instead of `.new`. A factory method should be created and reused instead of manually repeating the pattern. Add a factory method `static func restored(under durableRecording: DurableRecording?) -> SessionSidecarOrigin { durableRecording.map { .restored($0.sidecarWriter) } ?? .memoryOnly }` to `SessionSidecarOrigin`, then replace the inline pattern with `SessionSidecarOrigin.restored(under: routedLLM.durableRecording)`.