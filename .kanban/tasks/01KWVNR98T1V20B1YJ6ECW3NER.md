---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwvt1v1qwnt9vvzvc9pd2n0r
  text: |-
    Implementation complete. Summary of research + changes:

    **Research findings (macOS 27 SDK, FoundationModels.swiftmodule, and the pinned mlx-swift-lm checkout at .build/checkouts/mlx-swift-lm, branch mlx-foundationmodels, revision e6ccd2721):**
    - `FoundationModels.LanguageModelSession(model: some LanguageModel, tools:, instructions:)` is real and available at this macOS 27 SDK. `MLXFoundationModels.MLXLanguageModel` (in the pinned dependency) is a real, working `LanguageModel` conformance wrapping a lazily-loaded/cached `ModelContainer`.
    - Guided generation resolution: `MLXLanguageModel.Executor.respond(...)` already drives `MLXGuidedGeneration`'s `GrammarConstraint`/`GuidedGenerationLoop` **internally**, invoked by `LanguageModelSession.respond(to:schema:)` — so calling that Apple API is sufficient; no hand-rolled loop needed in Sources/FoundationModelsRouter.
    - Empirically verified (real run tests, not assumption) that `GenerationSchema`'s own `Codable` decode does NOT accept a caller's plain JSON Schema text — it requires proprietary `x-order`/`title` metadata and treats a titled string as a closed-enum carrier. Built `RuntimeJSONSchemaConverter` (hand-written JSON-Schema → `DynamicGenerationSchema` compiler) instead, covering object/array/scalar/closed-enum, matching exactly the subset `Grammar.validateForXGrammar()` already assumed supported. 11 real tests against actual FoundationModels types, all passing.
    - `Grammar.ebnf(_:)` is genuinely blocked: `LanguageModelSession` has no raw-grammar entry point, only typed `schema:`. Added `GuidedRequestError.ebnfNotSupportedByLanguageModelSession`.
    - `fork()`'s cheap-prefix-reuse mechanism (the "Sessions & KV cache" open question) is split/blocked: `LanguageModelSession.init(model:tools:transcript:)` (transcript-continuation) is real, but read `MLXLanguageModel.swift`'s `Executor.respond` directly — it re-derives the full model input from `request.transcript` and runs a fresh `MLXLMCommon.generate(...)` every turn; zero `KVCache`/`promptCache` references anywhere in `Libraries/MLXFoundationModels` (confirmed by grep). So there is no persisted-cache mechanism to wire fork() to at the pinned revision — this is an upstream dependency limitation, not a gap in our own wiring. `fork()` is kept as a correctness-only primitive (independent child session, nested transcript, freed on release).
    - Verified `LanguageModelSession.streamResponse`'s `ResponseStream.Snapshot.content` is a **cumulative snapshot**, not a per-token delta (checked the SDK interface directly) — adapted via suffix-diffing in the live container to preserve this codebase's existing delta/fragment stream contract.
    - Tool-call transcript recording gap: identified `Response<Content>.transcriptEntries`/`ResponseStream.Snapshot.transcriptEntries` as the mechanism to record toolCall/toolOutput events without instrumenting `Tool` conformances — but RoutedSession has no `tools:` parameter at all today, so nothing to wire it to yet; documented for when tool support is added.

    **Scope decision:** `LoadedLLMContainer`/`SessionKVCache`/`ModelLoader` protocol signatures were kept unchanged so ~10 existing unit test files (stub-based orchestration tests) needed zero changes. Only the live conformance (`LiveModelLoader.swift`) was rewritten. This keeps RoutedSession "forwarding to a real LanguageModelSession" true transitively through the live path while preserving GPU-free unit testability of orchestration.

    **Verification:** `swift build` clean, `swift build --build-tests` clean (includes gated integration target), `swift test` → 178/178 unit tests pass, gated real-model suite correctly skipped (no env var). plan.md updated throughout (Backends, Guided generation, Sessions & KV cache, Decisions, Milestones, Testing sections) with the above findings, each tied to what was actually checked.

    Adversarial double-check agent is running now to review this before final hand-off.
  timestamp: 2026-07-06T13:32:00.951240+00:00
- actor: claude-code
  id: 01kwvv5shb2zqgphtyc19xac6g
  text: |-
    Adversarial double-check (round 1) returned REVISE with 3 real findings, all addressed:

    1. (High) A doc comment I wrote on `GuidedRequestError.ebnfNotSupportedByLanguageModelSession` falsely claimed `.jsonSchema` guided generation works via `GenerationSchema`'s `Codable`/`JSONDecoder` round-trip — contradicting my own empirical finding elsewhere in the same diff that this decode is broken. Fixed: rewrote to correctly say `.jsonSchema` is supported via `RuntimeJSONSchemaConverter` instead.

    2. (Medium, real bug) `RuntimeJSONSchemaConverter` silently dropped enum constraints on non-string leaves (e.g. `{"type":"integer","enum":[1,2,3]}` compiled to a plain unconstrained `Int`, losing the constraint with no error) — contradicting the file's own "never silently mis-convert" invariant. Fixed: added `rejectUnsupportedEnum` check on the integer/number/boolean branches, throwing a typed `ConversionError` instead. Added a regression test.

    3. (Low) Converter tests only asserted "compiles without throwing," not that the produced schema was actually shaped correctly. Fixed: three tests now encode the compiled schema and assert on property names / required-set / enum choices via JSONEncoder round-trip; removed the superseded weaker duplicate tests.

    Verified fresh after fixes: `swift build` clean, `swift build --build-tests` clean, `swift test` → 179/179 pass (net +1: -2 weak tests, +3 stronger/regression tests). Re-spawned double-check once (bounded per really-done's contract) to confirm the fixes — awaiting that verdict before final hand-off.
  timestamp: 2026-07-06T13:51:39.051478+00:00
- actor: claude-code
  id: 01kwvv7m5arw2zd0p9wqc9ykyv
  text: |-
    Adversarial double-check round 2 (bounded re-check) returned PASS: all 3 findings from round 1 confirmed fixed with no new issues introduced (doc comment now accurate, enum-on-non-string-leaf now rejected with a typed error and a regression test, schema-shape assertions strengthened). Independently re-ran swift test: 179/179 pass.

    Final acceptance-criteria check:
    - [x] No code in Sources/FoundationModelsRouter constructs MLXLMCommon.ChatSession — removed entirely from LiveModelLoader.swift.
    - [x] No hand-rolled generation/tool-dispatch loop anywhere, including guided generation — GuidedGenerationLoop only runs inside MLXFoundationModels' own Executor, invoked by LanguageModelSession, never called directly by our Sources.
    - [x] RoutedSession's respond/streamResponse backed by LanguageModelSession via MLXLanguageModel — implemented (MLXFoundationModelsContainer); streamResponse's snapshot-vs-delta semantics verified against the real SDK and adapted, not assumed.
    - [x] fork()'s mechanism — split/blocked with a clear, source-verified rationale (pinned MLXLanguageModel.Executor has no persisted KV/prompt cache at revision e6ccd2721; confirmed by reading the dependency's own source, not assumed).
    - [x] Guided generation — implemented without a hand-rolled loop for typed/dynamic/raw-jsonSchema shapes via RuntimeJSONSchemaConverter (11+ real tests); .ebnf documented as genuinely blocked (no raw-grammar hook on LanguageModelSession) with a typed error.
    - [x] Transcript tool-call recording gap — documented with a concrete mechanism (Response/ResponseStream.transcriptEntries) for when tool support is added; not wired since RoutedSession has no tools: parameter today.
    - [x] Full test suite green — 179/179 unit tests, gated integration suite correctly skipped (no env var/network/GPU in this environment).
    - [x] plan.md reflects the as-built architecture — Backends, Guided generation, Sessions & KV cache, Decisions, Milestones, Testing sections all updated with verified findings, no stale aspirational language left for what's implemented.

    Task is done and verified. Leaving in `doing` for `/review` per the implement skill's contract (not moving to review myself).
  timestamp: 2026-07-06T13:52:39.082615+00:00
position_column: doing
position_ordinal: '80'
title: Adopt Apple LanguageModelSession as the actual session engine; remove ChatSession-based session path
---
## What

Currently `RoutedSession` (`Sources/FoundationModelsRouter/Session/RoutedSession.swift`) and `LiveModelLoader` (`Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift:21-52`) construct and drive **MLX's own `ChatSession`** (`MLXLMCommon`) directly — `FoundationModels` (Apple's framework) is never imported anywhere in `Sources/` or `Tests/`, despite the package name. This was confirmed by direct investigation: no `import FoundationModels`, no reference to `LanguageModelSession` anywhere outside vendored dependency doc comments.

We do **not** want a custom agent/session loop built on MLX's `ChatSession`, and we do **not** want any hand-rolled generation loop of our own anywhere in the stack (including the guided-generation path — see below). We want:

- **Apple's real `LanguageModelSession`** (`FoundationModels`, macOS 27+) to be the actual session object every caller talks to — not our own reimplementation of turn/tool-dispatch logic on top of `ModelContainer`/`ChatSession`.
- MLX's role narrowed to *supplying the model*: a resident `ModelContainer` conformed to Apple's `LanguageModel` protocol via `MLXLanguageModel` (from `MLXFoundationModels`, tracked at our fork `swissarmyhammer/mlx-swift-lm` branch `mlx-foundationmodels`, upstream PR [ml-explore/mlx-swift-lm#334](https://github.com/ml-explore/mlx-swift-lm/pull/334)).
- No hand-rolled generation/tool-call loop of our own, anywhere — multi-turn state, tool calling, `@Generable` decoding, and (per the open question below) guided/grammar-constrained generation all belong to `LanguageModelSession`/the `LanguageModel` conformance, not to code we write.

`plan.md` has been updated (Foundation, Dependency tracking, Access API, Backends, Guided generation, Sessions & KV cache, Sessions: working directory & isolation, Transcripts & recording, Decisions, Milestones, Testing sections) to reflect this as the target architecture, flip the "FoundationModels interop is available but not load-bearing" framing to load-bearing/primary, and flag two **open questions** that must be re-derived during implementation, not assumed:

1. **`fork()` / KV cache ownership** — the current `fork()` design was premised on owning MLX's KV cache directly via `KVCache.copy()` below `ChatSession`; under `LanguageModelSession`, cache/transcript ownership belongs to FoundationModels, so `fork()`'s actual mechanism must be re-derived from whatever prefix-reuse or transcript-continuation primitives `LanguageModelSession`/`MLXLanguageModel` expose in the macOS 27 SDK, not assumed to still be `KVCache.copy()` verbatim.
2. **Guided generation engine** — the current design (`GrammarConstraint(jsonSchema:)` + `GuidedGenerationLoop.run(…)` driving MLX sampling directly over `ModelContainer`) is itself a hand-rolled generation loop and contradicts the "no loop of our own" goal. It needs to be re-derived as something the `LanguageModel` conformance exposes *to* `LanguageModelSession` (so xgrammar constrains sampling underneath the conformance, invoked by FoundationModels), not "call `GuidedGenerationLoop.run` ourselves."

Additionally, an adversarial review (fable-model) of the plan.md pivot found and required fixing several places where the plan still asserted the old ChatSession/KVCache-premised design as settled fact instead of carrying the open-question caveats (e.g. "Sessions & KV cache" section body, the `RoutedSession` protocol doc comment, an integration-test assertion, and a gap around per-tool-call transcript recording if `LanguageModelSession` owns tool dispatch internally — recording `toolCall`/`toolOutput` events may require instrumenting `Tool` conformances directly, not just wrapping the outer `respond`/`streamResponse` chokepoint). All of these have been corrected in plan.md; this task's acceptance criteria below account for them.

## Scope of work

1. Research the actual `MLXLanguageModel` / `MLXFoundationModels` API surface on the `mlx-foundationmodels` branch (tip `234787d` as of 2026-06-29) — confirm what `LanguageModel` protocol conformance looks like, what `LanguageModelSession` construction over it requires, whether/how session forking, prefix reuse, or transcript continuation is exposed, and whether/how guided generation (grammar-constrained decoding) is exposed *through* the conformance rather than driven directly by us.
2. Rework `RoutedSession`/`RoutedSessionActor` to construct and forward to a real `LanguageModelSession` backed by `MLXLanguageModel`, instead of `ChatSession`.
3. Rework `LiveModelLoader`'s `respond`/`streamResponse` implementation accordingly. Confirm (or rework) `streamResponse`'s `AsyncThrowingStream<String, Error>` signature actually matches what `LanguageModelSession` streaming provides (token-delta vs. snapshot semantics) — do not assume the existing signature is correct without checking.
4. Resolve the `fork()` open question: determine the real mechanism available under `LanguageModelSession` for the "template session + fork" pattern, or document why it isn't currently achievable and what the fallback is.
5. Resolve the guided-generation open question: determine how `respond(to:generating:)`, `respond(to:matching:)`, `respond(to:following:)`, and `makeGuidedSession(_:)` can be implemented without a hand-rolled generation loop — i.e. via whatever the `LanguageModel`/`LanguageModelSession` surface actually exposes for grammar-constrained decoding — or document why a given shape isn't achievable and what the fallback is.
6. Address the transcript tool-call recording gap: if `LanguageModelSession` owns tool dispatch internally, determine how (or whether) `toolCall`/`toolOutput` events get recorded — via instrumenting `Tool` conformances, a `LanguageModelSession` observability hook, or documenting that this transcript detail is no longer available at the level we previously assumed.
7. Update/rework the existing test suite (unit + gated integration) to exercise the real `LanguageModelSession`-backed path. Do not write a `fork()` prefix-reuse/cache-release integration assertion until the mechanism from step 4 actually exists.
8. Update `plan.md` further if the research in step 1 changes assumptions baked into this task's description.

## Acceptance Criteria

- [ ] No code in `Sources/FoundationModelsRouter` constructs `MLXLMCommon.ChatSession` directly as the session surface; `RoutedSession` forwards to a real `LanguageModelSession`.
- [ ] No code in `Sources/FoundationModelsRouter` implements a hand-rolled generation/tool-dispatch loop of our own anywhere — this includes guided generation; `GuidedGenerationLoop.run(...)` driven directly by us over `ModelContainer` does not satisfy this criterion even if `ChatSession` itself is avoided.
- [ ] `RoutedSession`'s `respond`/`streamResponse` are backed by `LanguageModelSession` via `MLXLanguageModel`, not a hand-rolled generation loop. `streamResponse`'s signature has been verified (or reworked) against what `LanguageModelSession` streaming actually provides.
- [ ] `fork()`'s mechanism is either implemented against a real `LanguageModelSession`/`MLXLanguageModel` primitive, or the task is split/blocked with a clear written rationale for why it can't be resolved yet (e.g. upstream PR #334 doesn't yet expose what's needed).
- [ ] Guided generation (`respond(to:generating:)`, `respond(to:matching:)`, `respond(to:following:)`, `makeGuidedSession(_:)`) is either implemented without a hand-rolled loop of our own, or the task is split/blocked with a clear written rationale per shape that can't be resolved yet.
- [ ] The transcript tool-call recording gap is either resolved (toolCall/toolOutput events still captured) or explicitly documented as a known limitation with rationale.
- [ ] Full test suite green; existing behavior (sessions, streaming, guided generation, residency budgeting) is not regressed except where explicitly changed by this pivot.
- [ ] `plan.md` accurately reflects the as-built architecture (no remaining stale "aspiration"/"open question" language for anything actually implemented).
