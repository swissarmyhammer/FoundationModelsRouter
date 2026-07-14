---
comments:
- actor: claude-code
  id: 01kxgj61q14hdj1ze037gzcyvn
  text: |-
    Spike findings: the three facts all hold. Confirmed against the real Apple SDK swiftinterface (not just the fork's comments) at `/Applications/Xcode-beta.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`, cross-checked against the fork's actual implementation in `.build/index-build/checkouts/mlx-swift-lm/Libraries/MLXFoundationModels/MLXLanguageModel.swift` and `TranscriptConverter.swift`, and this repo's `Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift`.

    **Fact 1 — the generation entry point receives the full transcript every call.** There is no method literally named `generate` on `LanguageModel`; the real entry point is `LanguageModelExecutor.respond(to request: LanguageModelExecutorGenerationRequest, model: Self.Model, streamingInto channel: LanguageModelExecutorGenerationChannel) async throws` (swiftinterface line 1676, required by `protocol LanguageModel { associatedtype Executor: LanguageModelExecutor where Self == Self.Executor.Model }`, line 1440-1444). `LanguageModelExecutorGenerationRequest` (line 1849-1857) carries `public var transcript: FoundationModels.Transcript` — the full transcript, not a delta. Confirmed in the fork: `MLXLanguageModel.Executor.respond` converts it via `TranscriptConverter.mlxMessages(for: request.transcript)` (MLXLanguageModel.swift), i.e. the whole rendered chat history is rebuilt from `request.transcript` on every single call.

    **Fact 2 — MLXLanguageModel (and the protocol boundary generally) is stateless across calls w.r.t. transcript.** The fork's own doc comment on `preparedInputMappingImageFailures` states it explicitly: "`messages` is `LanguageModelExecutorGenerationRequest`'s full, re-rendered transcript, not just new content since the prior round (the `LanguageModelExecutor` protocol has no session identity — every `respond()` call receives the complete history again...)". This is exactly what `MLXFoundationModelsContainer.makeSession(transcript:)` in `LiveModelLoader.swift` already assumes/relies on: it rebuilds a brand-new `LanguageModelSession(model: model, tools: [], transcript: transcript)` from an arbitrary persisted transcript with no hidden per-model session state to restore — proven live by my own probe test's second test (`secondCallReceivesFullAccumulatedTranscriptAgain`): call 1's `request.transcript` has 1 entry, call 2's has 3 (prompt+response+prompt) — the full accumulated history, re-sent whole.

    **Fact 3 — a conforming wrapper can observe the response it emits.** Holds, but NOT via the mechanism I initially assumed. `LanguageModelExecutorGenerationChannel.Event` (swiftinterface line 1718) is a **write-only, opaque struct** — only static factory constructors (`.response(entryID:action:)` etc.), zero public accessors to read a value back out of an `Event` once built. So a wrapper that tries to relay another executor's *raw* channel events cannot introspect their content — that specific "channel-chaining relay" design does NOT work and should not be attempted for a recording handle. What DOES work, and is exactly what this repo's real `MLXFoundationModelsSessionBackend` already relies on: `LanguageModelSession.respond(to:)`'s return value is a plain, publicly readable `Response<String>` (`.content`). A wrapper's `Executor.respond` can build its own nested `LanguageModelSession` over the wrapped model, call `.respond(to:)`, read `.content`, record it, and then construct its own outgoing `.response(action: .appendText(content, tokenCount:))` event from that known text. Proved live in the probe test's first test: `ProbeResponseRecorder` captured the exact text ("stub says hello") the wrapper delegated to and re-emitted, and the outer session's own `response.content` matched it.

    **Implication for plan section 8**: the recording handle should observe emitted content at the `LanguageModelSession`/`Response.content` (or `session.transcript`) level — not by trying to decode another executor's `LanguageModelExecutorGenerationChannel.Event` stream, which is a write-only wire format with no public read path.

    Probe test: `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift` — `ProbeStubModel` (innermost stub `LanguageModel` conformer) wrapped by `PassthroughProbeModel` (passthrough wrapper `LanguageModel` conformer). TDD followed: first wrote the test with one intentionally wrong expected value (`"WRONG_INTENTIONAL_RED_VALUE"`), ran it, confirmed a genuine RED (compiled fine, failed only on the wrong value, and incidentally also caught a real bug in the probe itself — sharing one `ProbeTranscriptRecorder` between the stub and the wrapper conflated inner/outer transcript counts). Fixed both the recorder-sharing bug and the wrong value, reran: GREEN. `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer): full unit suite 305/305 passing, 0 failures/warnings; gated integration suites skip as expected (no GPU/network in this sandbox). No changes made inside `.build/checkouts/mlx-swift-lm` (read-only reference).
  timestamp: 2026-07-14T14:58:33.313484+00:00
- actor: wballard
  id: 01kxgjk54q9r4f1zrvs798e1z4
  text: 'Rename note: the consuming package FoundationModelsCodingHarness is now FoundationModelsAgentHarness (public repo: https://github.com/swissarmyhammer/FoundationModelsAgentHarness). The referenced plan lives at ../FoundationModelsAgentHarness/plan.md — ''plan section 8'' is unchanged. The engine type is now Agent (was CodingAgent).'
  timestamp: 2026-07-14T15:05:42.807112+00:00
- actor: claude-code
  id: 01kxgjk9e28f5q1v4nq9gm0gsb
  text: |-
    Adversarial double-check (via really-done's gate) ran against the probe test and returned REVISE with two findings, both fixed:

    1. `PassthroughProbeModel.Executor.Configuration`'s `==`/`hash(into:)` only considered the recorder actors' identity, omitting `wrapped` (the stub model it delegates to) — since the SDK caches executors keyed by `Configuration` equality (per `MLXLanguageModel.executorConfiguration`'s own doc comment), two configurations sharing recorders but wrapping different stub models could have collided in that cache. Fixed: `==`/`hash` now also fold in `wrapped.cannedResponseText` and `wrapped.transcripts`'s identity, mirroring how `ProbeStubModel.Executor.Configuration` already treats its own `cannedResponseText`.

    2. The doc comment on `ProbeStubModel.Executor.respond` claimed `stubTranscripts` was "recorded here for the test to inspect," but neither test actually asserted on it — only the wrapper-level recorder was checked. Fixed: added real assertions on `stubTranscripts` in both tests (the stub's own executor call transcript count, and that both of its two calls each carry exactly its own one-turn inner session's single `.prompt` entry), and reworded the doc comment to match what the tests actually do.

    Re-ran the full suite after both fixes: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests pass, 0 failures/warnings; gated integration suites skip as expected (no GPU/network in this sandbox). Second double-check pass not required per really-done's bounded-loop rule (fixes applied, one round is sufficient here — both findings were narrow, mechanical, and directly verified by the fresh green run).

    Task acceptance criteria and Tests checkboxes all checked off in the description. Leaving this in `doing` per /implement's contract — review is the next step's job, not mine.
  timestamp: 2026-07-14T15:05:47.202926+00:00
- actor: wballard
  id: 01kxgkdh9zvgjzw6405czqw07m
  text: |-
    Review addendum (swiftinterface re-read while folding findings into the dependent tasks) — four facts beyond the spike comment, all load-bearing for task 3:

    1. `LanguageModelExecutor.init(configuration:) throws` is a public protocol requirement, and `Model.executorConfiguration` is public — so a wrapper's executor can construct the wrapped model's own executor and call `respond(to:model:streamingInto:)` on it DIRECTLY, passing the OUTER channel straight through. That is the correct delegation mechanism for the recording handle: perfect event fidelity (streaming, reasoning, AND toolCalls events flow untouched), no re-encoding, no nested session.

    2. The nested-session delegation the probe test uses (PassthroughProbeModel) is right for the probe but WRONG for the real handle: a nested session would try to execute tool calls itself (it owns no tools) and break tool-using turns. The probe never exercises tools, so it couldn't see this.

    3. `LanguageModelExecutorGenerationChannel` has `public init()` and is itself an AsyncSequence of Event (public makeAsyncIterator/next), and `LanguageModelExecutorGenerationRequest` has a public memberwise init carrying `enabledToolDefinitions`, `generationOptions`, `contextOptions`, `id` — executor-level unit tests need no session at all, and tool definitions are available on the request directly. Event remains write-only (single extension, three static constructors, zero accessors) — the spike's fact-3 conclusion stands: relayed events cannot be inspected.

    4. Net design consequence: the turn-final response is unobservable at the executor boundary, full stop. Everything else (prompts, toolCalls, toolOutput, prior responses) is captured by diffing `request.transcript` per call. The handle therefore needs a small idempotent `sync(_ transcript:)` API called at turn end with `session.transcript` (public getter) by whoever owns the turn — harness Agent and the ACP bridge both already touch the session there. Task 3 and task 5 descriptions updated accordingly.
  timestamp: 2026-07-14T15:20:07.231378+00:00
- actor: wballard
  id: 01kxgkeex4389p5k15f4d32mze
  text: |-
    Review addendum (swiftinterface re-read while folding findings into the dependent tasks) — four facts beyond the spike comment, all load-bearing for task 3:

    1. `LanguageModelExecutor.init(configuration:) throws` is a public protocol requirement, and `Model.executorConfiguration` is public — so a wrapper's executor can construct the wrapped model's own executor and call `respond(to:model:streamingInto:)` on it DIRECTLY, passing the OUTER channel straight through. That is the correct delegation mechanism for the recording handle: perfect event fidelity (streaming, reasoning, AND toolCalls events flow untouched), no re-encoding, no nested session.

    2. The nested-session delegation the probe test uses (PassthroughProbeModel) is right for the probe but WRONG for the real handle: a nested session would try to execute tool calls itself (it owns no tools) and break tool-using turns. The probe never exercises tools, so it couldn't see this.

    3. `LanguageModelExecutorGenerationChannel` has `public init()` and is itself an AsyncSequence of Event (public makeAsyncIterator/next), and `LanguageModelExecutorGenerationRequest` has a public memberwise init carrying `enabledToolDefinitions`, `generationOptions`, `contextOptions`, `id` — executor-level unit tests need no session at all, and tool definitions are available on the request directly. Event remains write-only (single extension, three static constructors, zero accessors) — the spike's fact-3 conclusion stands: relayed events cannot be inspected.

    4. Net design consequence: the turn-final response is unobservable at the executor boundary, full stop. Everything else (prompts, toolCalls, toolOutput, prior responses) is captured by diffing `request.transcript` per call. The handle therefore needs a small idempotent `sync(_ transcript:)` API called at turn end with `session.transcript` (public getter) by whoever owns the turn — harness Agent and the ACP bridge both already touch the session there. Task 3 and task 5 descriptions updated accordingly.
  timestamp: 2026-07-14T15:20:37.540565+00:00
- actor: claude-code
  id: 01kxgkpw3kkv7a61hp0439hhp2
  text: |-
    Addressed all 5 review findings (2026-07-14 10:10) on LanguageModelBoundaryProbeTests.swift:

    1. Added doc comment on `ProbeStubModel.Executor` explaining it records request transcripts via `configuration.transcripts` for test assertions.
    2. Added doc comment on `PassthroughProbeModel.Executor` explaining it wraps the stub's executor, records observed transcript and response text, and delegates via a nested `LanguageModelSession`.
    3. Converted the cache-semantics `//` comment above `PassthroughProbeModel.Executor.Configuration`'s `==` into a proper `///` doc comment on the struct declaration itself (moved, not duplicated).
    4. Added response verification to `secondCallReceivesFullAccumulatedTranscriptAgain`: reads back `responses.responses` and asserts `count == 2` and `== ["ok", "ok"]` (the actual canned response text used in that test), placed right after the wrapper transcript assertions and before the stub-transcript checks.
    5. Added a doc comment on `PassthroughProbeModel.Executor.respond(to:model:streamingInto:)` matching the "Fact N in action" style of the sibling doc on `ProbeStubModel.Executor.respond`.

    Flipped all 5 `- [ ]` to `- [x]` in the Review Findings section (all other text preserved verbatim).

    Verification: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests pass, 0 failures/warnings; gated integration suites skip as expected (no GPU/network in sandbox). Adversarial double-check agent returned PASS, independently re-ran the full suite and the filtered probe-test-only run, confirmed each doc comment/assertion is accurate and correctly placed, confirmed "ok" is indeed the canned response text in that test, and confirmed no leftover duplicate comment.

    No changes made under .build/checkouts/mlx-swift-lm (vendored fork). Task left in `doing` per /implement's contract — review is the next step's job.
  timestamp: 2026-07-14T15:25:13.203336+00:00
- actor: claude-code
  id: 01kxgmnjb4gy3515tbc75q3d7q
  text: |-
    Addressed both Review Findings (2026-07-14 10:27) items on LanguageModelBoundaryProbeTests.swift:

    1. Added `/// Records a transcript observed on a probe model's executor call.` directly above `ProbeTranscriptRecorder.record(_:)`.
    2. Added `/// Records response text observed after delegation to the wrapped model.` directly above `ProbeResponseRecorder.record(_:)`.

    Flipped both `- [ ]` to `- [x]` in that section; all other sections (base description, Review Findings 10:10 section) preserved verbatim.

    Note: hit a kanban tooling quirk while updating the description — the `tag task` op appended literal "#coding-harness" text to the end of the description instead of registering the tag, and duplicated it on a second call, while the task's `tags`/`filter_tags`/`progress` fields also transiently zeroed out after a plain `update task` description edit. Cleaned this up by rewriting the description to the exact intended text (no stray trailing hashtags) and re-issuing the update, which caused tags (`coding-harness`) and progress (now 1.0) to recompute correctly. No lasting effect on this task's content; flagging in case the tag-task/update-task interaction is a real bug worth a task of its own.

    Verification: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests pass, zero warnings/failures; gated integration suites skip as expected (no GPU/network). Adversarial double-check agent returned PASS: diff scoped to exactly the two one-line doc-comment additions, style matches neighboring doc comments, vendored .build/checkouts/mlx-swift-lm untouched, and independently re-ran swift test with the same 305/305 zero-warning result.

    Leaving in `doing` per /implement's contract — review is the next step's job.
  timestamp: 2026-07-14T15:41:59.012760+00:00
- actor: claude-code
  id: 01kxgnh68mcq7gq7pmmcqn4vmf
  text: |-
    Addressed Review Findings (2026-07-14 10:43): extracted a private `setupProbes(cannedResponseText:)` helper on `LanguageModelBoundaryProbeTests` returning `(ProbeTranscriptRecorder, ProbeTranscriptRecorder, ProbeResponseRecorder, ProbeStubModel, PassthroughProbeModel)`, called from both `passthroughWrapperObservesTranscriptAndResponse` and `secondCallReceivesFullAccumulatedTranscriptAgain` (each destructuring with `_` for the unused raw stub, since neither test referenced it directly after wrapper construction). Moved the recorder-separation rationale comment into the helper's doc comment since that's now where the design choice lives.

    Verification: `swift test` (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests pass, 0 failures; only warning present is a pre-existing, unrelated SPM resource-bundle build note from the vendored mlx-swift-lm package's Cmlx bundle (not from our code, not new). No changes made under .build/checkouts/mlx-swift-lm.

    Kanban tooling quirk repeat: the first `update task` call to flip the checkbox corrupted the description (literal `\n` text appeared instead of real newlines) and zeroed out `tags`/`progress` again — same issue noted in an earlier comment on this task. Fixed with a follow-up `update task` call using real embedded newlines and re-supplying `tags: ["coding-harness"]`; re-fetched and confirmed real newlines and `tags: ["coding-harness"]` are now correct, progress back to 1.0.

    Adversarial double-check agent dispatched to verify the extraction is behaviorally identical (no accidental recorder sharing across test invocations, no lost assertions, no unused-variable warnings, doc comments accurate) — awaiting verdict before final hand-off.
  timestamp: 2026-07-14T15:57:04.148743+00:00
- actor: claude-code
  id: 01kxgnkg76sgkzwz853h1aw3g5
  text: |-
    Adversarial double-check returned PASS, no findings: extraction confirmed behaviorally identical (byte-for-byte matching construction logic, only the cannedResponseText literal parameterized), no shared state introduced (both recorder types are actors, setupProbes allocates fresh instances per call), no unused-variable warnings, doc comment accurately relocated, and diff scope confirmed limited to LanguageModelBoundaryProbeTests.swift plus this task's own kanban metadata files — nothing under .build/checkouts/mlx-swift-lm touched.

    All Review Findings (2026-07-14 10:43) checkboxes now [x]. Final verification: swift test (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests green, 0 failures, 0 warnings from our code (only the pre-existing, unrelated mlx-swift-lm Cmlx resource-bundle build note). Task description confirmed to have real newlines and tags: ["coding-harness"] intact via re-fetch. Leaving in `doing` per /implement's contract — ready for /review.
  timestamp: 2026-07-14T15:58:19.878406+00:00
- actor: claude-code
  id: 01kxgp2jk4ntn4xjfjx5d1xbqc
  text: |-
    Addressed Review Findings (2026-07-14 10:59): added a doc comment above ProbeStubModel.Executor.Configuration explaining it is the cache key the SDK uses to create/reuse this stub's executor (mirroring the sibling PassthroughProbeModel.Executor.Configuration doc's citation of MLXLanguageModel.executorConfiguration's "Configuration the framework uses to create and cache executors" comment), and explaining that ProbeTranscriptRecorder is a reference-type actor with no structural equality of its own, so == and hash(into:) compare/hash it by identity (=== / ObjectIdentifier) rather than by content — so each test's own recorder instance yields a distinct cache key even when cannedResponseText happens to match across tests.

    Flipped the single checkbox in Review Findings (2026-07-14 10:59) to [x]; all prior sections preserved verbatim. Confirmed via re-fetch: description has real newlines (not literal \n) and tags: ["coding-harness"] intact, progress 1.0 (hit the same kanban update-task tooling quirk noted in earlier comments on this task — first update call flattened newlines and zeroed tags; fixed with a second update call using real embedded newlines and re-supplying tags).

    Verification: swift test (DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer) — 305/305 unit tests green, 0 failures, 0 warnings (grepped test output for "warning": no matches). Gated integration suites skip as expected (no GPU/network in sandbox). No changes made under .build/checkouts/mlx-swift-lm.

    Adversarial double-check agent dispatched to verify the doc comment's technical accuracy and that no other code changed; awaiting verdict before final hand-off.
  timestamp: 2026-07-14T16:06:33.828417+00:00
- actor: claude-code
  id: 01kxgpcd3s2kfbzbx5114sq5sq
  text: |-
    Adversarial double-check returned PASS, no findings: diff scope confirmed to exactly 3 files (test file, 32 insertions/0 deletions, plus this task's two kanban metadata files) — no test logic, assertions, or .build/checkouts/mlx-swift-lm touched, pure doc-comment addition. Technical accuracy confirmed: ProbeTranscriptRecorder is indeed an actor with no synthesized Equatable/Hashable, the doc comment's description of == and hash(into:) behavior matches the code exactly, and the MLXLanguageModel.executorConfiguration doc-comment citation was independently verified against the vendored fork source and matches verbatim. Style check confirmed the new comment mirrors the sibling PassthroughProbeModel.Executor.Configuration doc's structure/citation pattern without being a verbatim copy-paste — it's adapted to this struct's own single-recorder field set. Independent swift test re-run: 305/305 green, 0 warnings from project code (only pre-existing unrelated mlx-swift-lm Cmlx resource-bundle build note).

    All Review Findings (2026-07-14 10:59) checkboxes now [x]. Task description re-confirmed to have real newlines and tags: ["coding-harness"] intact, progress 1.0. Leaving in `doing` per /implement's contract — ready for /review.
  timestamp: 2026-07-14T16:11:55.897864+00:00
position_column: doing
position_ordinal: '80'
title: 'Spike: verify LanguageModel generate boundary exposes the transcript (recording-handle prerequisite)'
---
## What
De-risk the recording-LanguageModel-handle design (FoundationModelsCodingHarness plan section 8) BEFORE building it. Read the fork product MLXFoundationModels (swissarmyhammer/mlx-swift-lm, branch foundationmodels-fixes) and Resolution/LiveModelLoader.swift here, and confirm three facts in writing:

- the LanguageModel protocol generate entry point receives the session transcript (or equivalent full-context input) on every call
- MLXLanguageModel is stateless across calls with respect to the transcript (fork/restore already assumes this — cite the exact code path)
- a conforming wrapper can observe the response it emits (needed to record the final response entry at turn end)

Record the findings as a comment on this task naming exact types, files, and signatures. If any fact does not hold, STOP this track and raise it — the dependent tasks must not start.

## Acceptance Criteria
- [x] A comment on this task documents the generate signature, transcript visibility per call, and the statelessness code path, with file/type names
- [x] A compiling probe test demonstrates a custom LanguageModel conformer wrapping another model can see the transcript passed in and the output passed back

## Tests
- [x] Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift — a passthrough LanguageModel conformer over a stub model; asserts the wrapper observed the transcript input and the emitted output (compilation is half the assertion)
- [x] swift test green (remember DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer)

## Workflow
- Use /tdd — the probe test IS the spike artifact.

#coding-harness

## Review Findings (2026-07-14 10:10)

- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:48` — Public struct `Executor` implementing protocol `LanguageModelExecutor` lacks documentation; developers reading this test need to understand what this nested type does. Add a doc comment above the `struct Executor:` declaration explaining its role in the test (e.g., "Executor conformance that records request transcripts for assertion by tests.").
- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:116` — Public struct `Executor` implementing protocol `LanguageModelExecutor` lacks documentation; mirrors the missing docs issue at line 48 for the passthrough wrapper's executor. Add a doc comment explaining this executor's role (e.g., "Executor that wraps another model's executor, records the observed transcript and response text, and delegates to the wrapped model via a nested session.").
- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:117` — Public struct `Configuration` for the passthrough executor lacks a doc comment; the cache-semantics comment (lines 122–130) is a regular comment, not a doc comment, so it is invisible to documentation tools and readers skimming the type. Add a doc comment above the struct declaration; move or duplicate the cache-semantics explanation into the doc comment.
- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:143` — The test makes two calls to `session.respond()` and verifies transcript recording for both calls, but does not verify response recording for either call. The ProbeResponseRecorder is created and passed to the wrapper (which records responses in its `respond()` method on each call), but the test never reads back the recorded responses. Add response verification to test 2 after the transcript assertions: `let recordedResponses = await responses.responses`, then `#expect(recordedResponses.count == 2)` and `#expect(recordedResponses == ["ok", "ok"])` to verify responses are recorded for both calls, matching the pattern used for transcript verification.
- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:146` — Public async function `respond(to:model:streamingInto:)` in `PassthroughProbeModel.Executor` lacks documentation, whereas the sibling function in `ProbeStubModel.Executor` (line 78) is fully documented, creating inconsistency. Add a doc comment explaining how this executor's `respond` method wraps the inner model, observes and records the response, and re-emits it.

## Review Findings (2026-07-14 10:27)

- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:17` — Public function `ProbeTranscriptRecorder.record(_:)` lacks a documentation comment explaining its purpose. Add a doc comment explaining that this method records a transcript for assertion in tests, e.g. `/// Records a transcript observed on a probe model's executor call.`.
- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:25` — Public function `ProbeResponseRecorder.record(_:)` lacks a documentation comment explaining its purpose. Add a doc comment explaining that this method records response text observed after delegation, e.g. `/// Records response text observed after delegation to the wrapped model.`.

## Review Findings (2026-07-14 10:43)

- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:248` — Test setup code (lines 248–252) duplicates setup from the first test (lines 214–218). Both initialize the same recorders and models with only the cannedResponseText differing. Should extract to a parameterized helper to eliminate the near-duplicate. Extract a helper method `func setupProbes(cannedResponseText: String) -> (ProbeTranscriptRecorder, ProbeTranscriptRecorder, ProbeResponseRecorder, ProbeStubModel, PassthroughProbeModel)` and call it from both tests, passing the differing cannedResponseText value.

## Review Findings (2026-07-14 10:59)

- [x] `Tests/FoundationModelsRouterTests/LanguageModelBoundaryProbeTests.swift:55` — ProbeStubModel.Executor.Configuration struct lacks documentation. This Configuration type has custom Equatable and Hashable implementations with subtle logic (ObjectIdentifier identity checks vs direct equality) that needs explanation. Add a documentation comment explaining the Configuration struct's purpose and why ObjectIdentifier is used for identity-based equality on the transcripts recorder.
