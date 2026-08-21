---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0hj2fn0rtsn1ezay1cegf5x
  text: |-
    ### Research — the stale text is still there, and I proved the true cause again from the tree

    I checked each fact of the card against the working tree, not against the card.

    **The stale text is still present.**
    - `plan.md`, "Sessions & KV cache": "currently expected to fail against the pinned revision (every `usage` this backend's `Executor` constructs hardcodes `cachedTokenCount: 0` ...)" and "there is no `KVCache`, prompt cache, or any persisted-across-turns state anywhere in `Libraries/MLXFoundationModels` (confirmed by grep: zero hits ...)".
    - `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, in `secondTurnReusesFirstTurnsKVCache`: "the executor-level KV-cache-reuse fix (tracked separately against the vendored mlx-swift-lm fork) has not landed against the pinned commit".

    **The sweep found six more present-tense sites, all in `plan.md`.** The card names two; the same wrong claim stands in six other paragraphs:
    1. The `RoutedSession` protocol comment block, "which has no persisted-cache state to copy at the pinned revision".
    2. Backends, "Resolved — `fork()`": the whole "What this primitive does **not** give back" paragraph, with the same zero-hits grep claim and revision `e6ccd2721`.
    3. "Sessions & KV cache": the "What is *not* recovered" paragraph.
    4. "Sessions & KV cache": the "Substrate previously verified below `ChatSession` (**confirmed absent** ...)" paragraph.
    5. "Sessions & KV cache": the "Budget caveat (moot at the pinned revision ...)" paragraph.
    6. Two entries of the milestone/status list near the end, "has no persisted-cache mechanism at the pinned revision" and "whose `MLXLanguageModel.Executor` has no persisted-cache mechanism to reuse it against".

    **Proof of the true cause, read from the checkout the `IntegrationTests` package actually builds** (`IntegrationTests/.build/checkouts/mlx-swift-lm`, HEAD `ba8ff43b9040ceec43c84f28637a250f33590633`):
    - `Libraries/MLXFoundationModels/ExecutorPromptCache.swift` exists. It carries `ExecutorPromptCacheStore` (an actor that holds one `[KVCache]` for each live session, LRU-bounded to 4), `ExecutorPromptCachePlan`, and `ExecutorPromptCacheSlot`.
    - `MLXLanguageModel.swift` stamps `cachedTokenCount: promptCache.reusedTokenCount`. It does NOT hardcode 0.
    - `ExecutorPromptCachePlan.make` opens with `guard input.image == nil, input.video == nil, input.audio == nil, input.text.mask == nil, input.text.tokens.ndim == 1 else { return nil }`.
    - `Libraries/MLXVLM/Models/MuseGlimmer.swift`, `MuseGlimmerProcessor.prepare(input:)`, text-only branch: `let promptArray = MLXArray(promptTokens).expandedDimensions(axis: 0)`, `let mask = ones(like: promptArray).asType(.int8)`, `return LMInput(text: .init(tokens: promptArray, mask: mask))`. Rank 2 and a mask, thus the guard refuses it.
    - So the plan is nil, generation runs with no carried cache, and the slot reports 0. No reuse and no report, from one cause.

    **A correction to one detail of the old text.** `trim(_:)`-style reuse IS reachable through the executor now: `reusablePromptPrefix` in `Libraries/MLXLMCommon/PromptCacheReusePolicy.swift` asks `canTrimPromptCache(caches)` and calls `rewindPromptCache(caches, to:)`. `KVCache.copy()` and `savePromptCache`/`loadPromptCache` are still unused by this path, so the "Substrate" paragraph needs a split, not a deletion.

    **Local pin drift, confirmed.** `.gitignore:17` ignores `Package.resolved`. Root `Package.resolved` holds branch `stable`, revision `acc920594fad346e416a0f633d96bd712d868460`, and its checkout has NO `ExecutorPromptCache.swift`. `IntegrationTests/Package.resolved` holds branch `stable`, revision `ba8ff43b9040ceec43c84f28637a250f33590633`, and its checkout HAS it. Both files are ignored, so this is local resolution drift on this machine, not a defect the repository tracks.
  timestamp: 2026-08-21T07:02:56.416499+00:00
- actor: claude-code
  id: 01m0hjegfnv6frp7k3qgc5wj9x
  text: |-
    ### implement — changed

    Nine sites, two files. The sweep went past the two the card names, because the same wrong claim stood in eight paragraphs of `plan.md`.

    **`plan.md`** — eight blocks:
    1. The `RoutedSession` protocol comment: the fork's executor "does carry a prompt cache at the pinned revision", so whether a child reuses the parent's prefix is that dependency's decision, not a missing mechanism.
    2. Section lead of "Sessions & KV cache": "a performance property of the vendored `mlx-swift-lm` fork, corrected on that fork's own board". The old text said "a dependency we don't control", which is wrong twice: the fork is ours, and the card for it is `^7fy0d2z`.
    3. Backends, "Resolved — `fork()`": cut to four lines that cite "Sessions & KV cache" instead of repeating its evidence. The old paragraph carried a second copy of the zero-hits grep claim and of revision `e6ccd2721`.
    4. The gated-test paragraph: the test "is red against the pinned revision, and the reason is the executor's own input guard, NOT a missing prompt cache", and "it turns green when the fork accepts the input this model's processor renders".
    5. The compute-reuse paragraph: now the one place that holds the evidence — the store, the stamp, the guard, `MuseGlimmerProcessor`, and `^7fy0d2z`.
    6. The "Substrate" paragraph: split by what the pinned revision reaches. `trim(_:)`-style reuse IS on the path through `reusablePromptPrefix`; `KVCache.copy()` and `savePromptCache`/`loadPromptCache` are not. It also records that the executor names a session by the identifier of the FIRST transcript entry, so a fork seeded from its parent's transcript names the SAME cache as its parent, and a check-out removes the entry.
    7. The budget caveat: no longer "moot at the pinned revision". The executor keeps one cache for each session key and bounds its store to four sessions, so the K× deep-copy cost is not real today.
    8. The two milestone/summary entries near the end of the document.

    **`LanguageModelSessionBackendTests.swift`** — the comment above the first assertion in `secondTurnReusesFirstTurnsKVCache`. It now names the store and the stamp, the guard and the rank-2 masked input the processor renders, the one cause behind both symptoms, and the fork card `^7fy0d2z`. The last line of the old comment — "This assertion is deliberately never weakened or made non-fatal" — is kept.

    **The pin drift is recorded twice**, and as local drift both times. `plan.md` carries the full statement under the heading "A local hazard, not a repository defect", with the two revisions and the reason (`Package.resolved` is gitignored, and the two packages resolve the branch independently). The test comment carries the short form, because that is where a reader meets the failure.

    **What did NOT change.** Both `#expect` calls, the tolerance, and every other line of the test. `git diff` over the Swift file shows only comment lines; every added and removed line starts with `//`.

    **No gated run.** I agree with the dispatching note. This card changes comment prose and markdown only, it touches no code path, and the test stays red for a cause tracked on the fork's board. A 23-minute gated run would prove nothing this build did not.

    **One card filed.** `^8894h7j` — `plan.md` cites the gated file as `Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, a path that moved into the nested package in `1db2b56`. It sits in a paragraph I rewrote, but it is not a claim about the prompt cache, so it goes on its own card with a sweep of every cited test path.

    - evidence: 2 files — `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/plan.md` (9 hunks), `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift` (comments only). Root `swift build --build-tests -Xswiftc -warnings-as-errors` complete; `IntegrationTests` `swift build --build-tests -Xswiftc -warnings-as-errors` complete. Root `swift test`: 1026 tests in 96 suites passed, and 77 tests in 9 suites passed.
    - next: `/review`
  timestamp: 2026-08-21T07:09:30.485397+00:00
position_column: doing
position_ordinal: '8180'
title: plan.md and the KV-cache test comment state a stale reason for the red cachedTokenCount test
---
Found while task ^de1yq0p looked for the cause of the red `secondTurnReusesFirstTurnsKVCache`. Two places in this repository state a reason that the pinned fork revision refutes. Both send the next reader down a dead end.

## What is stale

1. `plan.md`, section "Sessions & KV cache", says:
   - "every `usage` this backend's `Executor` constructs hardcodes `cachedTokenCount: 0`"
   - "there is no `KVCache`, prompt cache, or any persisted-across-turns state anywhere in `Libraries/MLXFoundationModels` (confirmed by grep: zero hits for `KVCache`/`promptCache`/`trim(`/`savePromptCache`)"
   - "It is currently expected to fail against the pinned revision"
   - It names the pinned revision as branch `mlx-foundationmodels`, revision `e6ccd2721`.

2. `IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/LanguageModelSessionBackendTests.swift`, inside `secondTurnReusesFirstTurnsKVCache`, says: "a zero cachedTokenCount here means the executor-level KV-cache-reuse fix (tracked separately against the vendored mlx-swift-lm fork) has not landed against the pinned commit".

## What is true

The `IntegrationTests` package pins the fork at branch `stable`, `ba8ff43b`. That revision carries `Libraries/MLXFoundationModels/ExecutorPromptCache.swift` (fork commit `08a120e`, "feat(foundation-models): reuse the prompt cache across turns"), and `MLXLanguageModel.swift` there stamps `cachedTokenCount: promptCache.reusedTokenCount`, not a hardcoded 0.

The fix HAS landed. It does not engage for `RealModels.standard`. `ExecutorPromptCachePlan.make` refuses any input whose tokens have `ndim != 1` or whose mask is not nil, and `MuseGlimmerProcessor.prepare(input:)` gives a rank-2, all-ones-masked input on its text-only branch. The whole evidence chain is on `^de1yq0p`, and the correction is filed on the fork's own board as `^7fy0d2z`.

## A second thing to record

The two packages of this repository resolve the same `stable` branch to DIFFERENT revisions: the root package sits at `acc9205`, which predates `ExecutorPromptCache.swift`, and `IntegrationTests` sits at `ba8ff43b`, which carries it. `Package.resolved` is gitignored, so this is local resolution drift, not a tracked defect. It still means the two `swift test` commands of one machine can build two different fork revisions, which makes a failure hard to reproduce. Say so where a reader will meet it.

## Acceptance Criteria

- [x] `plan.md` states the real reason the test is red, and names the revision that carries the prompt cache
- [x] The comment in `secondTurnReusesFirstTurnsKVCache` names the real reason and points at the fork card
- [x] Neither text claims the fork has no prompt cache
- [x] The assertion itself is unchanged
- [x] The pin divergence between the two packages is recorded where a reader meets it #integration #real-model