---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m34ywd6y7enw5wvpbz090nt4
  text: |-
    ### research — findings

    - The tokenizer is on the MLX `ModelContainer` (`container.tokenizer`, MLXLMCommon `Tokenizer`). `LiveModelLoader.loadLLM` already loads the container; it now keeps the tokenizer and gives `MLXFoundationModelsContainer` a `TokenizerTokenCounter`.
    - The MLX generation path renders a transcript through `TranscriptConverter` (internal to MLXFoundationModels) and `tokenizer.applyChatTemplate(messages:tools:)`. The router cannot call that converter, so `TranscriptChatMessages` renders the same shape: instructions as the system message, tool definitions as function specifications, tool calls as an assistant message with calls, tool outputs as tool messages by id, and no reasoning entry. A tokenizer with no chat template gets the same plain-text fallback the MLX LLM processor uses.
    - `LoadedLLMContainer` gets a required `tokenCounter`. The 43 scripted containers in `Tests/` supply `CharacterTokenCounter` (one token per `Character`) from `FoundationModelsRouterTestSupport`. The public-surface test target links the library alone by design, so its container states its own rule in its file.
    - The overflow retry (^m39wmx1) halves the configured target and divides by no estimate, so this card does not change it. A note on ^m39wmx1 says the session now owns `tokenCounter`.
    - `UTF8Budget`, `TranscriptEntryPayload.contentByteCount`, `RouterSegmentSchemaNames` and `CompactionTokenAccountingTests` lose their last user with the estimate and are deleted.
    - `summaryBytesPerWordEstimate` (words stated to the model) stays: the stated byte budget now comes from the bytes of the first N tokens of the text itself (`counter.prefix`), not from a conversion factor.
  timestamp: 2026-09-22T16:23:46.654599+00:00
- actor: claude-code
  id: 01m3504bj7tt2ssrj0sg417gq8
  text: |-
    ### implement — changed
    - evidence: Sources — new Compaction/TokenCounter.swift (protocol: count text, count transcript, prefix), new Resolution/TokenizerTokenCounter.swift (live counter over the MLX tokenizer, chat-template rendering through TranscriptChatMessages, plain-text fallback when the tokenizer has no template); LoadedLLMContainer.tokenCounter (required), MLXFoundationModelsContainer/LiveModelLoader keep the loaded tokenizer, RoutedLLM.tokenCounter (public), RoutedSessionActor.tokenCounter threaded through makeRoutedSessionActor at the vend, fork and restore sites; Compactor.compact(counter:) and Summarization.apply(counter:) count every size in tokens (shrinkMarginTokens = 1, summaryTokenBudget in tokens, cut/condense/chunk in tokens, stated words from the bytes of the first N tokens); ToolOutputCapping.capped(text:toTokenLimit:counter:) encodes, keeps the first limit tokens, decodes, marker states limit of total. Deleted: charsPerTokenEstimate, estimatedTokenCount, estimatedTokens(of:), characters(forEstimatedTokens:), shrinkMarginBytes, contentByteCount, UTF8Budget, RouterSegmentSchemaNames.
    - evidence: Tests — CharacterTokenCounter (one token per Character) in FoundationModelsRouterTestSupport; 45 scripted containers supply a counter; SummarizationStageTests and ToolOutputCappingTests restated in tokens with the acceptance test (1,500 passes uncut; 1,501 cut to 1,500, marker "1500 of 1501"); new TokenizerTokenCounterTests; CompactionTokenAccountingTests deleted (its subject is gone); ScriptedTurnSizingTests calibrates against 1496 measured tokens over 7338 characters; eval support and real-model support take a counter parameter; IntegrationTests count with the loaded container's counter; RecordCompactionFixture tool counts with profile.standard.tokenCounter.
    - evidence: rg 'charsPerTokenEstimate|estimatedTokenCount|estimatedTokens\(' Sources finds nothing.
    - next: test
  timestamp: 2026-09-22T16:45:35.687086+00:00
- actor: claude-code
  id: 01m3504dved0wh25mj5015q9de
  text: |-
    ### test — green
    - evidence: swift test — 1353 tests in 145 suites passed, 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failed, 0 skipped. The 2 known issues are pre-existing withKnownIssue marks in RealModelHarnessTests.swift and BoundedWaitTests.swift, files this change does not touch. swift build --build-tests: no compiler warning. swift build --package-path IntegrationTests --build-tests: Build complete (real-model suites are gated and left to CI).
    - next: commit
  timestamp: 2026-09-22T16:45:38.030104+00:00
- actor: claude-code
  id: 01m35055ztmhccxn728bswcjpa
  text: |-
    ### commit — changed
    - evidence: 32b6a63 feat(compaction): count tokens with the model's tokenizer; delete charsPerTokenEstimate
    - next: review
  timestamp: 2026-09-22T16:46:02.746023+00:00
- actor: claude-code
  id: 01m3553xc1rvh9jrb68qea0hj8
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD — 8 findings, 8 confirmed, 0 refuted. RecordingHandleResumeTests.swift:421, RoutedSessionCompactTests.swift:236, :301, :406, SessionRestorationTests.swift:62, SummarizationStageTests.swift:1, TokenizerTokenCounterTests.swift:32, ToolOutputProtectionTests.swift:253.
    - next: implement
  timestamp: 2026-09-22T18:12:44.033740+00:00
- actor: claude-code
  id: 01m355hvkm4d2t72zxgs4y9x6p
  text: |-
    ### implement — changed
    - evidence: 8 findings worked. RecordingHandleResumeTests.swift:421 now says "token count". RoutedSessionCompactTests.swift: a `private static let characterTokenCounter` is added, the three counts use `Self.characterTokenCounter`, and the other "character count" comments in the file now say "token count". SessionRestorationTests.swift: BasicLLMContainer states its own `tokenCounter`. TokenizerTokenCounterTests.swift: ScriptedTokenizer is a plain `Sendable` class (each stored property is an immutable Sendable value; `renders` is a Mutex). ToolOutputProtectionTests.swift:253 says "in tokens". SummarizationStageTests.swift is split: the reasoning-headroom, no-op, failure and Compactor.compact tests move word for word (diff-checked) to the new SummarizationStageCompactorTests.swift as an extension of the same suite; the shared helpers are internal. The head file is now 89,897 bytes (126,461 before).
    - next: test
  timestamp: 2026-09-22T18:20:20.980697+00:00
- actor: claude-code
  id: 01m355hxgzvrft6d07qzeqdkkd
  text: |-
    ### test — green
    - evidence: swift test — 1353 tests in 145 suites passed, 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failed. The 2 known issues are the pre-existing withKnownIssue marks in RealModelHarnessTests.swift and BoundedWaitTests.swift. swift build --build-tests: no compiler warning (the one SwiftPM line "missing creator for mutated node ... mlx-swift_Cmlx.bundle" comes from the build system for the MLX dependency, not from the code). swift build --package-path IntegrationTests --build-tests: Build complete.
    - next: commit
  timestamp: 2026-09-22T18:20:22.943771+00:00
- actor: claude-code
  id: 01m355j4jkt8qm1a3jqvzyrvq4
  text: |-
    ### commit — changed
    - evidence: 90ca217 fix(review): state token counts in the test fixtures; split SummarizationStageTests under the review prompt cap
    - next: review
  timestamp: 2026-09-22T18:20:30.163348+00:00
- actor: claude-code
  id: 01m35684e1ph1ydsyces1z65as
  text: |-
    ### review — findings
    - evidence: review sha HEAD~1..HEAD (90ca217) — 1 finding, 1 confirmed, 9 refuted. SummarizationStageTests.swift:45 (no_unchecked_sendable on ScriptedSummarizer).
    - next: implement
  timestamp: 2026-09-22T18:32:30.913540+00:00
- actor: claude-code
  id: 01m356a7kb8w3hw7rbd4h2wedw
  text: |-
    ### implement — changed
    - evidence: SummarizationStageTests.swift — ScriptedSummarizer is now a plain `Sendable` class: `responses` is immutable, and the received prompts and ceilings are in a `Mutex`. `receivedPrompts` and `receivedMaxTokens` read the Mutex. No `@unchecked Sendable` is left in SummarizationStageTests.swift or SummarizationStageCompactorTests.swift. The file is 90,459 bytes, under the review prompt cap.
    - next: test
  timestamp: 2026-09-22T18:33:39.691861+00:00
- actor: claude-code
  id: 01m356a8zg7hgrt8r6rrmxb958
  text: |-
    ### test — green
    - evidence: swift test — 1353 tests in 145 suites passed, 1 test in 1 suite passed, 83 tests in 10 suites passed; 0 failed; 2 pre-existing known issues (RealModelHarnessTests.swift, BoundedWaitTests.swift). swift build --build-tests: no compiler warning. swift build --package-path IntegrationTests --build-tests: Build complete.
    - next: commit
  timestamp: 2026-09-22T18:33:41.104907+00:00
- actor: claude-code
  id: 01m356aeg3azzztah5ekjwx6xg
  text: |-
    ### commit — changed
    - evidence: 4839061 fix(review): make ScriptedSummarizer a plain Sendable class over a Mutex
    - next: review
  timestamp: 2026-09-22T18:33:46.755503+00:00
- actor: claude-code
  id: 01m356dfjrh4mb7pnzce9y0zp6
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (4839061) — 0 findings, 0 confirmed, 0 refuted. Every prior finding is checked (9 of 9).
    - next: verify
  timestamp: 2026-09-22T18:35:26.168447+00:00
- actor: claude-code
  id: 01m356dsd4q0spbhx171jyk8pp
  text: |-
    ### finish iteration 1 — done
    - implement: changed — 32b6a63 (earlier agent: TokenCounter, TokenizerTokenCounter, capping in tokens, estimate deleted); then 8 findings of review 12:30 worked (RecordingHandleResumeTests.swift, RoutedSessionCompactTests.swift, SessionRestorationTests.swift, TokenizerTokenCounterTests.swift, ToolOutputProtectionTests.swift, SummarizationStageTests.swift split into SummarizationStageCompactorTests.swift); then 1 finding of review 13:20 worked (ScriptedSummarizer is a plain Sendable class over a Mutex)
    - test: green — swift test: 1353 tests in 145 suites passed, 1 test in 1 suite passed, 83 tests in 10 suites passed, 0 failed, 2 pre-existing known issues; swift build --build-tests: no compiler warning; swift build --package-path IntegrationTests --build-tests: Build complete
    - commit: 32b6a63, 90ca217, 4839061
    - review: clean — review sha HEAD~1..HEAD at 4839061: 0 findings; all 9 prior findings checked. Earlier passes: 12:30 findings at RecordingHandleResumeTests.swift:421, RoutedSessionCompactTests.swift:236, :301, :406, SessionRestorationTests.swift:62, SummarizationStageTests.swift:1, TokenizerTokenCounterTests.swift:32, ToolOutputProtectionTests.swift:253; 13:20 finding at SummarizationStageTests.swift:45
    - acceptance: rg 'charsPerTokenEstimate|estimatedTokenCount|estimatedTokens\(' Sources finds nothing
  timestamp: 2026-09-22T18:35:36.228578+00:00
position_column: done
position_ordinal: ffffe380
title: Count tokens with the model's tokenizer; delete charsPerTokenEstimate
---
## Decision (from the owner, 2026-09-22)

`Compactor.charsPerTokenEstimate` (4.0, `Compaction/Compactor.swift:119`) is a guess and must go. Every token count the router makes before a model call comes from the loaded model's own tokenizer. After a call, the exact `usage.input` (^j6b24gd) is the count.

## Why

- Code and JSON run near 3 characters per token, so the estimate undercounts by about a quarter, in the direction that hides an overflow. On django__django-13964 (2026-09-21) the estimate said about 225,000 tokens for a context that was over the 262,144 window.
- The tokenizer is already loaded with the model: `context.tokenizer.encode(text:addSpecialTokens:)` (`Resolution/LiveModelLoader.swift:488`), used by the embedding path today.

## Sites

- `Compactor.swift:117-119`: the constant. `:306-334` `estimatedTokenCount(of:)` (transcript and text) and `estimatedTokenCount(bytes:)`.
- `Summarization.swift:61` `shrinkMarginBytes`, `:730-733` `characters(forEstimatedTokens:)`, `:816-821` `estimatedTokens(of:)`, and every division by the estimate (`:337, :747`). Most of these go with ^pke18c2; what remains counts with the tokenizer.
- `Session/ToolOutputCapping.swift:18`: the host's `toolOutputLimit` (tokens) is applied in bytes through the estimate. Apply it in tokens: encode the result, keep the first `limit` tokens, decode them back, and state the true counts in the marker.
- The evals (`Tests/FoundationModelsRouterEvalSupport`) report sizes "in the same estimate"; they report tokenizer counts instead.
- Tests that assert estimated counts (`CompactionTokenAccountingTests`, `ToolOutputCappingTests`, fixtures that compute expected sizes as bytes ÷ 4).

## Do this

1. Add a `TokenCounter` the session owns, backed by the loaded container's tokenizer: `count(_ text: String) -> Int` and `count(_ transcript: Transcript) -> Int` (the rendered form the model sees, instructions included). The scripted test backends supply a counter of their own (a test may define its own rule; the number lives in the test).
2. Give the counter to `Compactor.compact`, `Summarization`, the capping layer, and the overflow retry computation (^m39wmx1). Delete the constant and every function that divides by it.
3. `shrinkMarginBytes` becomes "the summary must count at least one token less than the span it replaces", in tokens.
4. Update the tests: expected counts come from the test's counter, not from bytes ÷ 4.

## Order

Before ^pke18c2 (the one-call compaction), which needs the counter for the summary's allowed size and the summarizer window check. ^m39wmx1 can use the counter or land first with `usage.input`; say which on that card when this one lands.

## Acceptance

- `rg 'charsPerTokenEstimate|estimatedTokenCount|estimatedTokens\('` finds nothing in `Sources`.
- A tool output of 1,500 tokens by the model's tokenizer passes a `toolOutputLimit` of 1,500 uncut; one of 1,501 is cut to 1,500 tokens with a marker that states 1,500 of 1,501.
- All tests pass. #compaction #limits

## Review Findings (2026-09-22 12:30)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 90 file(s) reviewed, 7 not reviewed.

> ⚠️ 1 file(s) not reviewed — the rendered prompt would exceed the agent's prompt cap:
> - `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift` — 336782 rendered bytes, over the 262144-byte per-file cap; not reviewed by: duplication (split the file)

> 6 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 6 file(s)

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Sources/FoundationModelsRouter/Core/UTF8Budget.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/disallowed-constructs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> disallowed-constructs-swift found no file at Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, so its constructs are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Sources/FoundationModelsRouter/Core/UTF8Budget.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/function-length-swift' declined an item — it judged the rest of the code, and this it could not judge:
> function-length-swift found no file at Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, so its bodies are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Sources/FoundationModelsRouter/Core/UTF8Budget.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/idioms-swift' declined an item — it judged the rest of the code, and this it could not judge:
> idioms-swift found no file at Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Sources/FoundationModelsRouter/Core/UTF8Budget.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/magic-numbers-swift' declined an item — it judged the rest of the code, and this it could not judge:
> magic-numbers-swift found no file at Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, so its literals are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Sources/FoundationModelsRouter/Core/UTF8Budget.swift, so its declarations are unread

> ⚠️ tool rule 'code-hygiene/missing-docs-swift' declined an item — it judged the rest of the code, and this it could not judge:
> missing-docs-swift found no file at Tests/FoundationModelsRouterTests/CompactionTokenAccountingTests.swift, so its declarations are unread

- [x] `Tests/FoundationModelsRouterTests/RecordingHandleResumeTests.swift:421` `swift/naming-clarity` — The doc comment uses 'character count' which is misleading terminology after switching from character-based estimation to token-based counting. The term 'character count' specifically means counting characters, but this change moves all measurement to token-based counting via TokenCounter. Using 'character count' in this context violates clarity by using terminology that contradicts what the system now does. Change line 421 from 'carries a real character count' to 'carries a real token count' to accurately reflect that the measurement system is now token-based, not character-based.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift:236` `completeness/invariant-propagation` — The code uses `characterTokenCounter.count(...)` throughout test methods but never defines this variable, while ScriptedTurnSizingTests properly defines its counter at the class level (line 36: `private static let counter = CharacterTokenCounter()`). The same pattern should be followed for consistency. Add `private static let characterTokenCounter = CharacterTokenCounter()` to the RoutedSessionCompactTests class body, following the same pattern as ScriptedTurnSizingTests.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift:301` `completeness/invariant-propagation` — The code uses `characterTokenCounter.count(...)` but this variable is never defined in the test class, consistent with the same issue at line 236. Define `private static let characterTokenCounter = CharacterTokenCounter()` at the test class level to fix all occurrences.
- [x] `Tests/FoundationModelsRouterTests/RoutedSessionCompactTests.swift:406` `completeness/invariant-propagation` — The code uses `characterTokenCounter.count(...)` but this variable is never defined in the test class, consistent with the same issue at lines 236 and 301. Define `private static let characterTokenCounter = CharacterTokenCounter()` at the test class level to fix all occurrences.
- [x] `Tests/FoundationModelsRouterTests/SessionRestorationTests.swift:62` `completeness/invariant-propagation` — tokenCounter property added to SeedCapturingContainer (line 60-62), but BasicLLMContainer (lines 41-45) is a sibling container in the same file that was left unchanged. Both are test fixtures in SessionRestorationTests; the task description states 'every scripted container supplies a counter', implying both should receive the treatment. Add tokenCounter property to BasicLLMContainer: `let tokenCounter: any TokenCounter = CharacterTokenCounter()`.
- [x] `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift:1` `review-engine/prompt-cap` — This file exceeds the review prompt cap — 336782 rendered bytes against the 262144-byte per-file cap — so these validators could not review it: duplication. Split the file into smaller modules that fit the review prompt cap.
- [x] `Tests/FoundationModelsRouterTests/TokenizerTokenCounterTests.swift:32` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
- [x] `Tests/FoundationModelsRouterTests/ToolOutputProtectionTests.swift:253` `swift/naming-clarity` — The doc comment states 'The size, in characters' but the variable name is `protectedOutputTokens` and the context of this change is converting to token-based counting. The comment should clearly reflect that this measures tokens, not characters. Update the comment to 'The size, in tokens, of the protected tool output the fixture holds.' to accurately document that this property counts tokens.

## Review Findings (2026-09-22 13:20)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 7 file(s) reviewed, 2 not reviewed.

> 2 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 2 file(s)

- [x] `Tests/FoundationModelsRouterTests/SummarizationStageTests.swift:45` `code-hygiene/disallowed-constructs-swift` — no_unchecked_sendable: Instead of @unchecked Sendable, write a plain Sendable conformance or a @preconcurrency import. If the type really must be @unchecked Sendable, write // swiftlint:disable:next no_unchecked_sendable above it with the synchronization invariant that makes the type thread-safe.
