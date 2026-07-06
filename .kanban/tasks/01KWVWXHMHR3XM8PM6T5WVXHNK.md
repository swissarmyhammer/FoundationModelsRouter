---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwvzhgm5g360vsew5676dp12
  text: '/finish scoped-batch run: picked up this task (lowest ordinal, ready, unblocks the session-backend chain). Starting implement.'
  timestamp: 2026-07-06T15:07:57.445884+00:00
- actor: claude-code
  id: 01kww0pfdq23by8q25fs05ga8n
  text: |-
    Implemented:
    - New Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift protocol (respond, streamResponse, respond(following:), makeFork), class-bound + Sendable.
    - ModelLoader.swift: LoadedLLMContainer now exposes only makeSession(instructions:) -> any LanguageModelSessionBackend; removed the three stateless generation methods and makeCache().
    - GuidedGeneration.swift: removed the default LoadedLLMContainer extension for respond(to:instructions:following:maxTokens:).
    - SessionKVCache.swift: removed the default LoadedLLMContainer.makeCache() extension (SessionKVCache protocol + InertKVCache class kept).

    Beyond the literal "Modify" list, also updated the other production (Sources/) call sites that referenced the removed protocol members, since the task's own acceptance criterion requires the whole `swift build --target FoundationModelsRouter` to keep succeeding, not just the 3 listed files:
    - LiveModelLoader.swift: MLXFoundationModelsContainer.makeSession(instructions:) now returns a new MLXFoundationModelsSessionBackend class holding the moved respond/streamResponse/respond(following:) bodies (behaviorally unchanged: fresh LanguageModelSession per call). makeFork() returns an equivalent fresh backend for now (no transcript state to seed from yet) -- real transcript-seeded fork is task 00pe5cf's job.
    - RoutedLLM.swift: container.makeCache() replaced with InertKVCache() directly.
    - RoutedSession.swift (RoutedSessionActor): respond/streamGenerating now call container.makeSession(instructions:) once per call to get a backend, then drive it -- preserves today's exact per-call-fresh-session behavior. Deliberately did NOT make the actor hold the backend as persistent state across calls or add serialGate-guarded fork (that's task rqgzwa4's explicit scope).

    Verification: `swift build --target FoundationModelsRouter` succeeds (exit 0). `swift build --build-tests` fails only in the test target (stub containers missing makeSession(instructions:)) -- expected/permitted per the task's note; task qzwtm1m fixes those stubs.

    Leaving task in doing for review per /implement workflow.
  timestamp: 2026-07-06T15:28:08.631263+00:00
- actor: claude-code
  id: 01kww119jw91n9s04a5ttvj76x
  text: |-
    Adversarial double-check (via really-done) ran: verdict REVISE with one finding — SessionKVCache.swift's "Historical note" doc comment still said "the live container inherits the inert default below unchanged," which became stale once makeCache()'s default extension was deleted (RoutedLLM.swift now constructs InertKVCache() directly, not via any container-inherited default). Fixed the wording to describe the new mechanism accurately. Everything else the double-check checked passed: protocol shape matches spec verbatim, ModelLoader.swift/GuidedGeneration.swift/SessionKVCache.swift diffs match the task's 4 required changes exactly, no remaining Sources/ call sites reference the removed container methods, and the task1-vs-task2/task3 scope boundary was judged sound (no preemption of MLXFoundationModelsSessionBackend's @unchecked Sendable/session-accessor/transcript-fork work, no preemption of RoutedSessionActor's persistent-backend/cache-removal/serialGate-fork work).

    Re-verified after the fix: `swift build --target FoundationModelsRouter` still exits 0 ("Build complete!"). Task is green and ready for /review; leaving in doing.
  timestamp: 2026-07-06T15:34:03.100550+00:00
- actor: claude-code
  id: 01kww1420ea595pkvft97a2250
  text: 'Implement landed green: production target (`swift build --target FoundationModelsRouter`) builds clean. `swift test` fails to build only because `StubLLMContainer` (ProfileLifecycleTests.swift) and `CannedLLMContainer` (ToolIntegrationTests.swift) don''t yet implement `makeSession(instructions:)` — this is the exact, documented, expected gap called out in this task''s own description ("Test targets are expected to fail to compile until task 4 — do not attempt to fix stubs here"). Fixing those stubs is task 01KWVWZJMYGB295V9C0QZWTM1M''s job, not this one''s. Treating this as the accepted test state and proceeding to commit + review.'
  timestamp: 2026-07-06T15:35:33.646462+00:00
- actor: claude-code
  id: 01kww21tszzcnqdhw9gtqc5bkc
  text: |-
    Addressed all 8 review findings (unlabeled first parameter on factory/method signatures). Changes:

    - Sources/FoundationModelsRouter/Resolution/ModelLoader.swift: `ModelLoader.loadLLM(_ ref:...)` -> `loadLLM(ref:...)`, `loadEmbedder(_ ref:...)` -> `loadEmbedder(ref:...)` (protocol requirements).
    - Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift: matching `ref:` label added to all 4 conforming implementations (`LiveModelLoader.loadLLM`, `LiveModelLoader.loadEmbedder`, `UnconfiguredModelLoader.loadLLM`, `UnconfiguredModelLoader.loadEmbedder`) — required for protocol conformance once the requirement's label changed. Also updated the stale `` ``LiveModelLoader/loadEmbedder(_:slot:reporting:)`` `` doc-link to `(ref:slot:reporting:)`.
    - Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift: `makeGuidedSession(_ grammar:...)` -> `makeGuidedSession(grammar:...)`; updated its one call site (`makeGuidedSession(grammar).respond(...)` -> `makeGuidedSession(grammar: grammar).respond(...)`).
    - Sources/FoundationModelsRouter/Session/RoutedSession.swift: private `streamGenerating(_ prompt:...)` -> `streamGenerating(prompt:...)`; updated its call site in `streamResponse(to:maxTokens:)`.
    - Sources/FoundationModelsRouter/Router.swift: updated the two production call sites that invoke the now-relabeled protocol methods positionally: `loader.loadLLM($0,...)` -> `loader.loadLLM(ref: $0,...)`, `loader.loadEmbedder($0,...)` -> `loader.loadEmbedder(ref: $0,...)`.
    - Sources/FoundationModelsRouter/RoutedLLM.swift and Session/RoutedSession.swift: fixed 3 stale doc-comment cross-references (`` ``RoutedModel/makeGuidedSession(_:instructions:workingDirectory:)`` ``) to the new `(grammar:instructions:workingDirectory:)` form.

    Verified `swift build --target FoundationModelsRouter` still exits 0 ("Build complete!") — production build stayed green throughout.

    Side effect worth flagging for whoever picks up the stub-fixing task (01KWVWZJMYGB295V9C0QZWTM1M or similar): relabeling the `ModelLoader` protocol's `loadLLM`/`loadEmbedder` first parameter means every test-double `ModelLoader` conformance (in Tests/FoundationModelsRouterTests/*.swift and Tests/FoundationModelsRouterIntegrationTests/IntegrationTests.swift — roughly a dozen stub types) also needs its local `func loadLLM(_ ref: ...)`/`func loadEmbedder(_ ref: ...)` declarations relabeled to `ref:`, or the test target will report a *second*, distinct class of protocol-conformance error (label mismatch) on top of the already-documented missing-`makeSession` gap. Confirmed via `swift build --build-tests`: it still fails, now citing both the pre-existing missing-`makeSession` errors and this label-mismatch error in IntegrationTests.swift. Per this task's explicit scope (fix only the 8 cited production-file findings, do not touch test stubs), I left the test doubles alone — production build only, per the acceptance criterion.
  timestamp: 2026-07-06T15:51:49.311613+00:00
- actor: claude-code
  id: 01kww356dnfecwsr8wy0w6d941
  text: |-
    Picked back up from review to address the second review-findings entry: LiveModelLoader.swift:98 deep-nesting finding (AsyncThrowingStream closure -> Task closure -> do-catch -> for -> if, 5+ levels).

    Fix: extracted MLXFoundationModelsSessionBackend.streamResponse(to:maxTokens:)'s do/catch/for/if body into a new `private static func pumpStream(prompt:options:model:instructions:into:) async` method. streamResponse now only builds GenerationOptions, captures model/instructions as locals, and returns AsyncThrowingStream { continuation in Task { await Self.pumpStream(...) } } -- the stream closure's Task body is a single await call, no control flow directly nested inside it. pumpStream builds its own LanguageModelSession and does the do/catch/for/if at 3 levels inside a standalone async function, same behavior (delta/suffix computation, finish()/finish(throwing:), continuation.onTermination cancellation) preserved verbatim.

    Scanned the rest of the file for the same shape: loadLLM's nested load:/progressHandler: closures are straight-line calls with no if/for/do-catch inside, so not the same pattern -- left alone.

    Verified: `swift build --target FoundationModelsRouter` exits 0 (Build complete!). `swift build --build-tests` still fails with the same pre-existing label-mismatch errors (loadLLM(_:...) vs required loadLLM(ref:...) in IntegrationTests.swift stubs) -- unchanged from before this fix, deferred to task 01KWVWZJMYGB295V9C0QZWTM1M as documented.

    Spawned double-check agent for adversarial review of the extraction before handoff.
  timestamp: 2026-07-06T16:11:08.085314+00:00
- actor: claude-code
  id: 01kww5p2b554kj3dh4q8brhyr8
  text: |-
    Picked back up from review to address the "Review Findings (2026-07-06 11:17)" round (8 items, all in LiveModelLoader.swift):

    1. Duplication finding: extracted a private `respond(to prompt:schema:maxTokens:)` helper on `MLXFoundationModelsSessionBackend` that builds the session, runs the appropriate `session.respond` overload (schema vs no-schema), and returns the right content variant (`response.content` vs `response.content.jsonString`). `respond(to:maxTokens:)` now just calls `respond(to:schema:nil,maxTokens:)`. Initially only wired the plain-path call site through the helper and left the `.jsonSchema` case of `respond(to:following:maxTokens:)` with its old inline duplicate logic — caught this gap via a self-review pass (`mcp__sah__review`) before handoff and fixed it: the `.jsonSchema` case now does `let schema = try RuntimeJSONSchemaConverter.compile(schemaText); return try await respond(to: prompt, schema: schema, maxTokens: maxTokens)`.
    2-8. Fixed all 7 cited doc-comment "first line must end in period" findings, and per the task's instruction to scan the whole file for the same recurring pattern, found and fixed 11 more not explicitly cited (defaultMaxTokens, MLXFoundationModelsContainer, MLXFoundationModelsSessionBackend, its model/instructions properties, streamResponse, pumpStream, suffix, respond(following:), LiveEmbeddingContainer, its init/embed, static embed(_:in:), weightsLocation, loadEmbedder on LiveModelLoader, configuration(for:), handler(_:)). Verified programmatically (Python scan of every `///` block) that zero doc comments in the file now have a first line that doesn't end in `.`.

    Verification: `swift build --target FoundationModelsRouter` exits 0 ("Build complete!"). `swift build --build-tests` still fails with the same pre-existing, documented label-mismatch errors in test stubs (`loadLLM(_:...)` vs required `loadLLM(ref:...)`) — unchanged, deferred to task 01KWVWZJMYGB295V9C0QZWTM1M.

    Ran a fresh `mcp__sah__review` pass after the fix: the duplication finding is gone. It surfaced a NEW, different class of findings (unlabeled first parameters on `embed`/`preload`/`evict`/`handler`, missing param/throws docs on `preload`/`evict`) that are out of scope for this task's cited findings — filed as new task 01KWW5MGY5CKV1NF8D0Q19R0EP rather than scope-creeping this one.

    Only Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift changed (git diff --stat confirms). Ran really-done; adversarial double-check in progress. Leaving task in doing for review.
  timestamp: 2026-07-06T16:55:18.117133+00:00
- actor: claude-code
  id: 01kww5t8ngwwmqphw1d6wq4txf
  text: 'Adversarial double-check (via really-done) returned PASS, no blocking findings: independently confirmed (1) exactly one private respond(to:schema:maxTokens:) helper exists and BOTH call sites (respond(to:maxTokens:) and the .jsonSchema case of respond(to:following:maxTokens:)) route through it with no leftover inline duplication, (2) spot-checked well over 10 doc blocks spanning the whole file and confirmed no first line is left without a terminating period, (3) swift build --target FoundationModelsRouter exits 0 fresh, (4) only LiveModelLoader.swift (plus this task''s own kanban tracking files) changed. Task is green and ready for /review; leaving in doing.'
  timestamp: 2026-07-06T16:57:35.664608+00:00
- actor: claude-code
  id: 01kwwe36x51fvvh29hpd83jtx1
  text: |-
    Addressed the "Review Findings (2026-07-06 12:00)" round and reconciled the two older unchecked rounds:

    New fixes (2 of 3):
    1. `LiveEmbeddingContainer.embed(_:)` -> `embed(texts:)`. Also relabeled the `LoadedEmbeddingContainer` protocol requirement in ModelLoader.swift (conformance requires an exact label match) and the one call site outside LiveModelLoader.swift: RoutedEmbedder.swift's `container.embed(texts)` -> `container.embed(texts: texts)`.
    2. static `embed(_:in:)` -> `embed(texts:in:)`. Updated both call sites in LiveModelLoader.swift (the instance method's body, and loadEmbedder's dimension probe).

    Declined (with justification, documented on the card): marking `handler` `private`. It's already `internal` (module-only, not public API) so `private` only tightens visibility by one notch. Applying it breaks `Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift`'s `handlerMapsIncrementalBytes` test, which calls `LiveModelLoader.handler { ... }` directly via `@testable import` — `@testable` lifts `internal` access but never `private` (strictly file-scoped), so there's no way to satisfy both. Verified by making the change: `swift build --build-tests` produced a brand-new failure (`'handler' is inaccessible due to 'private' protection level`) that didn't exist before, distinct from the already-documented/deferred stub gaps. Reverted; `handler` stays `internal`. Tried asking via the question tool first; it was declined/no interactive answer was available, so proceeded with the lower-risk call (keep the test green over a marginal encapsulation gain).

    Reconciled the two older unresolved rounds, which prior sessions had already fixed but left unchecked:
    - 2026-07-06 11:17 duplication finding (LiveModelLoader.swift:61): confirmed `respond(to:maxTokens:)` and the `.jsonSchema` case of `respond(to:following:maxTokens:)` both delegate through the private `respond(to:schema:maxTokens:)` helper with no remaining duplicated session-construction logic. Checked off.
    - 2026-07-06 11:17 doc-comment-period findings (6 cited lines + the file generally): read every `///` doc block in LiveModelLoader.swift; all first lines end in a period. Checked off.

    `swift build --target FoundationModelsRouter` is green. `swift build --build-tests` fails only with the pre-existing, already-deferred gaps: missing `makeSession(instructions:)` on `StubLLMContainer`/`CannedLLMContainer`, and `loadLLM`/`loadEmbedder`/`embed` label mismatches on test-double conformances (the last one is new *in kind* but same *category* as the already-documented label-mismatch debt, and is explicitly covered by task 01KWW5MGY5CKV1NF8D0Q19R0EP's "relabel any test-double conformances" instruction) — task 01KWVWZJMYGB295V9C0QZWTM1M's scope, untouched here.

    Leaving task in doing for review; one item (handler private) intentionally left unchecked with the justification above for the user/reviewer to weigh in on.
  timestamp: 2026-07-06T19:22:17.381934+00:00
- actor: claude-code
  id: 01kwwe6jtfqgxvsams88h7hbdf
  text: |-
    really-done verification: `swift build --target FoundationModelsRouter` exits 0 fresh. Adversarial double-check (via really-done) returned PASS: diff is exactly 3 files / 7 insertions / 7 deletions matching the two accepted embed-relabeling findings precisely (LiveModelLoader.swift's instance+static embed, doc-link, and dimension-probe call site; ModelLoader.swift's LoadedEmbeddingContainer protocol requirement; RoutedEmbedder.swift's one call site); `grep -rn "\.embed(" Sources/` shows no remaining unlabeled call to the protocol's embed anywhere (the one other unlabeled `model.embed(texts)` in Tools.swift calls the deliberately-unchanged public RoutedEmbedder.embed(_:) API, out of scope); and `LiveModelLoader.handler` is confirmed unchanged (still `static func handler(`, no `private`), consistent with the declined-with-justification item above.

    Task is green and ready for /review; leaving in doing. One item (marking `handler` private) is intentionally left unchecked with its justification recorded above for the reviewer/user to weigh in on if they disagree with the call.
  timestamp: 2026-07-06T19:24:07.887288+00:00
position_column: doing
position_ordinal: '80'
title: Define LanguageModelSessionBackend protocol and make LoadedLLMContainer a factory
---
## What

Replace the stateless generation methods on `LoadedLLMContainer` with a single factory method. The container no longer invokes generation directly — it manufactures session objects that do.

**New file:** `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`

```swift
/// A live session object vended by a LoadedLLMContainer factory.
/// Holds state (conversation transcript) across calls.
public protocol LanguageModelSessionBackend: AnyObject, Sendable {
    func respond(to prompt: String, maxTokens: Int?) async throws -> String
    func streamResponse(to prompt: String, maxTokens: Int?) -> AsyncThrowingStream<String, Error>
    func respond(to prompt: String, following grammar: Grammar, maxTokens: Int?) async throws -> String
    /// Produces a new backend seeded from this session's accumulated transcript.
    func makeFork() -> any LanguageModelSessionBackend
}
```

**Modify** `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift`:
- Add `func makeSession(instructions: String?) -> any LanguageModelSessionBackend` to `LoadedLLMContainer`
- Remove the three stateless generation methods: `respond(to:instructions:maxTokens:)`, `streamResponse(to:instructions:maxTokens:)`, `respond(to:instructions:following:maxTokens:)`
- Remove `makeCache() -> any SessionKVCache`

**Modify** `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift`:
- Remove the `LoadedLLMContainer` default extension for `respond(to:instructions:following:grammar:maxTokens:)`

**Modify** `Sources/FoundationModelsRouter/Session/SessionKVCache.swift`:
- Remove the `LoadedLLMContainer.makeCache()` default extension

**Note on compilation:** Removing the stateless protocol methods will cause test targets to fail to compile until task 4 updates the stubs. That is expected and accepted. Only `Sources/` production code must compile after this task.

## Acceptance Criteria
- [x] `LanguageModelSessionBackend` protocol exists in `Sources/FoundationModelsRouter/Session/LanguageModelSessionBackend.swift`
- [x] `LoadedLLMContainer` in `ModelLoader.swift` has only `makeSession(instructions:) -> any LanguageModelSessionBackend`; the three stateless generation methods and `makeCache()` are gone from the protocol
- [x] `swift build --target FoundationModelsRouter` (production sources only) succeeds
- [x] Test targets are expected to fail to compile until task 4 — do not attempt to fix stubs here

## Tests
- [x] `swift build --target FoundationModelsRouter` exits 0

## Workflow
- Use `/tdd` — define the protocol and strip the container seam, verify production target compiles, leave test failures for task 4.

## Review Findings (2026-07-06 10:36)

- [x] `ModelLoader.swift:66` — The first required parameter `ref` should have a label. Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `ModelLoader.swift:84` — The first required parameter `ref` should have a label. Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:165` — Change `makeGuidedSession(_ grammar: Grammar,` to `makeGuidedSession(grammar: Grammar,`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:119` — Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:148` — Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:253` — Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:270` — Change `_ ref: ModelRef,` to `ref: ModelRef,`.
- [x] `Sources/FoundationModelsRouter/Session/RoutedSession.swift:232` — Change `_ prompt: String,` to `prompt: String,`.

## Review Findings (2026-07-06 11:00)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:98` — Function has 5+ levels of nesting; extract the streaming logic into a helper function.

## Review Findings (2026-07-06 11:17)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:61` — Duplication between `respond(to:maxTokens:)` and the `.jsonSchema` case of `respond(to:following:maxTokens:)`. Resolved by a private `respond(to:schema:maxTokens:)` helper on `MLXFoundationModelsSessionBackend`; both call sites route through it (confirmed 2026-07-06: `respond(to:maxTokens:)` calls the helper directly, and the `.jsonSchema` case compiles its schema and calls the same helper — no remaining duplicated session-construction logic).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:231` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:237` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:318` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:368` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:380` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:391` — doc-comment first line now ends in a period (confirmed 2026-07-06).
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:405` — doc-comment first line now ends in a period (confirmed 2026-07-06).

## Review Findings (2026-07-06 12:00)

- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:228` — `LiveEmbeddingContainer.embed(_:)` relabeled to `func embed(texts: [String]) async throws -> [[Float]]`. Updated the `LoadedEmbeddingContainer` protocol requirement in `ModelLoader.swift` (must match for conformance) and the one production call site, `RoutedEmbedder.swift`'s `container.embed(texts: texts)`.
- [x] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:233` — static `embed(_:in:)` relabeled to `static func embed(texts: [String], in container: EmbedderModelContainer) async throws -> [[Float]]`. Updated its two call sites (`LiveEmbeddingContainer.embed(texts:)`'s body and `loadEmbedder`'s dimension probe).
- [ ] `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:431` — **Declined, with justification.** `handler` is already `internal` (module-only visibility, not part of the package's public API) — marking it `private` only tightens visibility from "whole module" to "single file," a marginal stylistic gain. Applying it breaks `Tests/FoundationModelsRouterTests/LiveModelLoaderTests.swift`, which calls `LiveModelLoader.handler { ... }` directly via `@testable import` to unit-test the Foundation-`Progress`-to-`DownloadProgress` byte-mapping adapter in isolation. `@testable` lifts `internal` access but never lifts `private` (which is strictly file-scoped) — there is no way to keep both the stricter access and that test's direct-call design. Confirmed by making the change: `swift build --build-tests` showed a *new* failure (`'handler' is inaccessible due to 'private' protection level`) not present before, distinct from the already-documented/deferred missing-`makeSession`/label-mismatch gaps. Reverted the `private` marker; `handler` stays `internal`. Asked the user for a decision via the question tool; the prompt was declined (no interactive answer available), so proceeding with the lower-risk choice (keep the test green) rather than force a new regression for a marginal encapsulation gain.
