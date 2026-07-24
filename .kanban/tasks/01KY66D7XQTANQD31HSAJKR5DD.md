---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01ky9daqentktpxkd08jhpj01s
  text: |-
    Investigated: the duplication described in this task's "What" section no longer exists in the current file. respond(to:maxTokens:) already calls generate exactly once via respondBody(grammar: grammar, maxTokens: maxTokens), and dispatchNextPrompt() shares the same helper. This was fixed by commit 445e870 (\"refactor(session): extract shared helpers for grammar-branch and prompt-mutation duplication\", 2026-07-22 20:28:15 -0500) — landed shortly after this task was filed (2026-07-23T00:36 UTC creation timestamp), as a side effect of resolving a different task's findings, and this card was never closed out to match.

    Verification run fresh in this session:
    - swift build: clean, 0 warnings
    - swift build --build-tests: clean, 0 warnings
    - swift test: 506 tests (484+17+5 across 51+7+2 suites), 0 failures — matches current baseline exactly
    - review working (scoped to RoutedSession.swift): 0 findings
    - diagnostics check on the file: 0 errors, 0 warnings

    All three acceptance criteria are satisfied by code already in main. No further code changes made — this was a verification-only pass. Leaving in doing for review.
  timestamp: 2026-07-24T06:34:44.565915+00:00
- actor: claude-code
  id: 01ky9e1c2vs9bq2fc7rymx4p79
  text: 'Addressed the 2026-07-24 01:35 review finding on replace(_:prompt:)''s unlabeled first arg. Investigated per instructions rather than blindly applying the suggested fix: confirmed RoutedSession.enqueue(prompt:)/cancel(_:)/replace(_:prompt:) are siblings designed together in task ndv3sc1 (explicitly documented there as "cancel(id) / replace(id, prompt)" pair), and a codebase-wide grep for `public func \w+\(_ \w+:` confirms an unlabeled-first-arg verb+direct-object convention is widespread (append(_:to:), sync(_:usage:), post(_:), save(_:), apply(_:), session(_:), noteCompaction(_:), cancel(_:)). replace(_:prompt:) matches this convention exactly (same shape as append(_:to:)/sync(_:usage:)) and is not a make*-factory case, so it does not match the one finding from the earlier k36zy10 batch that was genuinely fixed. Verdict: no code change, finding checked off with reasoning recorded in the task description. Re-verified swift build / swift build --build-tests / swift test all green (506 tests, 0 failures, no new warnings) — pure no-op as expected. Left in doing for /review.'
  timestamp: 2026-07-24T06:47:06.587165+00:00
position_column: doing
position_ordinal: '80'
title: Dedupe generate() calls in RoutedSession.respond(to:maxTokens:)
---
## What

A fresh `review working` pass (2026-07-22, while resolving task 9drp1rz's findings) found a new, unrelated duplication: `Sources/FoundationModelsRouter/Session/RoutedSession.swift`'s `respond(to:maxTokens:)` has two nearly-identical branches that both call `generate`, differing only in whether `grammar` is passed and which `backend.respond` overload the closure calls:

```swift
if let grammar {
    return try await generate(grammar: grammar, prompt: prompt) { composedPrompt in
        try await backend.respond(to: composedPrompt, following: grammar, maxTokens: maxTokens)
    }
}
return try await generate(prompt: prompt) { composedPrompt in
    try await backend.respond(to: composedPrompt, maxTokens: maxTokens)
}
```

Reviewer's suggested fix: unify into a single `generate(grammar: grammar, prompt: prompt) { ... }` call, moving the `if let grammar` backend-dispatch decision inside the closure.

## Acceptance Criteria
- [x] `respond(to:maxTokens:)` calls `generate` exactly once, with the grammar/no-grammar backend dispatch decided inside the closure
- [x] `swift build`, `swift build --build-tests`, `swift test` all green, no regressions
- [x] `review working` on the file finds zero recurrence of this finding

## Note
Pre-existing code, not introduced by task 9drp1rz — logged separately per "no unrelated refactors while implementing" convention rather than folded into that task's fix. #bug

## Resolution
Already fixed by commit 445e870 ("refactor(session): extract shared helpers for grammar-branch and prompt-mutation duplication", 2026-07-22 20:28:15 -0500), landed as a side effect of resolving a different task shortly after this card was filed. `respond(to:maxTokens:)` and `dispatchNextPrompt()` both now funnel through `respondBody(grammar:maxTokens:)`, which owns the single `if let grammar` branch. Verified in this pass: swift build/build-tests/test all clean (506 tests, 0 failures), `review working` on the file returns 0 findings, diagnostics clean. No further code changes were needed.

## Review Findings (2026-07-24 01:35)

- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:385` — First argument label omitted (`_`) for `replace` when multi-parameter methods must label their arguments unless the first is a value-preserving conversion — this is a side-effectful method, not a conversion. Change signature to `public func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt)`.

### Resolution (2026-07-24) — no code change, matches established convention

Investigated instead of blindly applying the suggested fix. Verdict: **leave as-is** — `replace(_:prompt:)`'s unlabeled first argument is a deliberate, verified convention match, not an oversight.

Evidence:
1. **Sibling design, same origin task.** `RoutedSession.enqueue(prompt:)`, `cancel(_:)`, and `replace(_:prompt:)` are declared together in the same protocol extension (lines ~313-378) and were designed together in task 01KY5TAQJV8XQE8GC9HNDV3SC1 ("Prompt queue: enqueue, inspect, edit, cancel, and driver dispatch of queued user prompts"), whose own description states them as a pair: "`cancel(id)` / `replace(id, prompt)` — mutate a queued prompt before dispatch." Both are thin, effectful forwards to `SessionOutbox`'s own `cancel(id:)`/`replace(id:prompt:)` (which DO label `id:` at that lower layer) — `RoutedSession`'s wrappers deliberately drop the label on the first argument to match `cancel(_:)`'s shape, since both take "the id of the queued item to act on" as their direct object.
2. **Convention is real and widespread, not a one-off.** A codebase-wide grep for `public func \w+\(_ \w+:` turns up unlabeled-first-arg verb+direct-object effectful methods throughout, including several multi-parameter ones matching `replace(_:prompt:)`'s exact shape (unlabeled direct object + a second labeled parameter): `GatingRecorder.append(_:to:)`, `Sinks` conformances' `append(_:to:)` (x3), `RecordingLanguageModel.sync(_:usage:)`. Plus single-arg siblings: `SessionOutbox.post(_:)`, `HostProfileCache.save(_:)`, `ToolOutputElision.apply(_:)`, `TurnTruncation.apply(_:)`, `TranscriptRecorder.append(_:)`, `SessionTreeRestoration.session(_:)`, `TranscriptTree.session(_:)`, `RecordingLanguageModel.noteCompaction(_:)`. `RoutedSession.cancel(_:)` itself is one more instance living right next to `replace(_:prompt:)`.
3. **Distinguished from the genuinely-fixed `make*` case** (per the earlier k36zy10 investigation in this same review batch): that finding was a `make*`-prefixed factory method, and this codebase's convention labels factory parameters while leaving verb+direct-object effectful methods unlabeled on the first argument. `replace` is a verb+direct-object effectful method (replace the queued item at this id), not a factory, so it falls on the unlabeled side of that same convention, not the labeled side.

No code change made. Verified via fresh `swift build` (clean, 0 warnings beyond the known pre-existing `mlx-swift_Cmlx.bundle` warning), `swift build --build-tests` (clean), and `swift test` (506 tests: 484+17+5 across 51+7+2 suites, 0 failures) — matching baseline exactly, confirming this pass was a no-op as expected. Left in `doing` for the next `/review` pass.