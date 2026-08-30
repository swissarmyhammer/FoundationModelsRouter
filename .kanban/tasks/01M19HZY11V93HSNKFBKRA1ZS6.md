---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m19jjt8npe3vyykywetr4zz2
  text: |-
    Research done. Measured, not guessed.

    1. Baseline public symbol count reproduces at 621, the number the card names. The extractor needs the four flags ^cdrxcyc recorded, plus one more this tree makes necessary: `-I <bin>` itself, not only `-I <bin>/Modules`. There IS no `Modules` directory under `.build/out/Products/Debug` here; the module sits directly in the bin directory. With `-I <bin>/Modules` alone the extract still succeeds, but it reads a stale module and reports 620, and `TranscriptEvent.merged(under:)` is absent from its list. Adding `-I <bin>` gives 621 and the merged entry point appears. A count of 620 is therefore the signal of a bad extract, not of a lost symbol.

    2. The consumer's line is served by the proposed signature. FoundationModelsMultitool/Sources/FoundationModelsMultitool/Capabilities/Shell/Execute.swift reads `let context = ToolContext.current` and then `let commandID = context?.completionToken ?? SessionMailbox.makeCompletionToken()`. Both halves are on `ToolContext` after this change.

    3. `ULID` is `@_exported import`ed by Sources/FoundationModelsRouter/Core/ULID.swift, so a plain import sees the type. But `ULID.init?(_:)` and `ULID.stringLength` are internal to this package, so only a `@testable` file can use them. That splits the tests: the plain-import file asserts uniqueness and the consumer's expression; the shape comparison against the internal mint belongs in ToolContextTests.swift, which is `@testable`.

    4. Precedent for placement: ^cdrxcyc put `extension TranscriptEvent { public static func merged(under:) }` at the foot of MergedTranscript.swift, the file that holds the internal implementation it forwards to. The same shape applies here, so the public forwarder goes at the foot of Hosting/SessionMailbox.swift, beside the internal mint it calls.

    5. Precedent for the plain-import probe: Tests/FoundationModelsRouterTests/GuidedPublicSurfaceTests.swift and Tests/FoundationModelsRouterTests/MergedTranscriptPublicSurfaceTests.swift. `@testable` is per file, so one plain-import file in the ordinary unit test target is enough for the compiler to be the first assertion.
  timestamp: 2026-08-30T14:53:37.941127+00:00
- actor: claude-code
  id: 01m19k0tcdspdhf8tz0w3av7sn
  text: |-
    TDD record, in order.

    RED. The three tests were written before the source change. `swift build --build-tests` stopped with `type 'ToolContext' has no member 'makeCompletionToken'` at ToolContextTokenPublicSurfaceTests.swift lines 30, 43 and 44. The failure is the missing feature, not a typo.

    GREEN. The extension was added, and all three tests pass.

    Three notes on the tests, so a later reader does not weaken them.

    1. `eachCallMintsADistinctToken` mints 64 tokens and asserts the SET has 64 members. The card asks only that two calls differ, and two calls would pass against a mint that repeated itself now and then — a clock read with no random low bits, for one. The set assertion catches that as well as it catches a constant.

    2. `theConsumerExpressionFallsBackToAFreshMint` asserts `ToolContext.current?.completionToken == nil` FIRST. Without that line the two assertions under it would be true even if some enclosing run had supplied the token, and the test would say nothing about the mint. The line makes the fallback the branch the test is measuring.

    3. `publishedMintMatchesTheMailboxTokenShape` parses BOTH tokens as ULIDs, not only the published one. Asserting the published token alone would state a shape the test itself chose; parsing both states the shape the two mints share, which is what the card asks for.

    Two decisions to state.

    Placement. The public forwarder sits at the foot of Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift, beside the internal mint it calls, in the same shape ^cdrxcyc used for `TranscriptEvent.merged(under:)` at the foot of MergedTranscript.swift. The internal mint's doc comment names the public entry point, so a reader of either one finds the other.

    The doc comment names `SessionMailbox` in plain single backticks with the word "internal", never as a ``link``. Commit `5379087` set that rule: a doc comment refers to an internal symbol that way, because a DocC link to an internal symbol does not resolve. `ToolContext/current` and `ToolContext/completionToken` are public, so those are written as links.

    The downstream call site is served. FoundationModelsMultitool writes
    `let commandID = context?.completionToken ?? SessionMailbox.makeCompletionToken()`
    and it becomes `ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()`,
    at the same type and the same result type. No file in that repository was changed.
  timestamp: 2026-08-30T15:01:16.813942+00:00
- actor: claude-code
  id: 01m19k12ak5x5rfdxx370gr2yg
  text: |-
    ### implement — changed
    - evidence: 3 files. Source: Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (one `extension ToolContext` holding the public `makeCompletionToken()`, plus two lines on the internal mint naming that entry point). Tests: Tests/FoundationModelsRouterTests/ToolContextTokenPublicSurfaceTests.swift (new, plain import, 2 tests), Tests/FoundationModelsRouterTests/ToolContextTests.swift (+1 test).
    - public surface: 621 -> 622 symbols. The diff of the two symbol lists holds exactly one added line, `s:22FoundationModelsRouter11ToolContextV19makeCompletionTokenSSyFZ`, and no removed line. Measured with `swift-symbolgraph-extract -minimum-access-level public` over the built module, before the change and after it.
    - `SessionMailbox` and `SessionMailbox.makeCompletionToken()` are unchanged and still internal. The extracted list holds 0 rows naming `SessionMailbox`.
    - `swift test`: 1127 tests in 123 suites passed (1124 in 122 before), plus 83 tests in 10 suites in the evals target. 0 failures. The 2 known issues are the pre-existing `RealModelHarness` and `BoundedWait` ones.
    - `swift build --package-path IntegrationTests --build-tests`: Build complete. The one warning is SwiftPM's pre-existing `missing creator for mutated node` on the mlx-swift bundle, which no change here touches.
    - next: /review
  timestamp: 2026-08-30T15:01:24.947873+00:00
- actor: claude-code
  id: 01m19k52eksa0t71xng60sd8r9
  text: |-
    ### test — green
    - evidence: `swift test` at root — 1127 tests in 123 suites passed (2 known issues: RealModelHarness, BoundedWait — pre-existing tripwires) + 83 tests in 10 suites passed = 1210 passed, 0 failed, 0 skipped. 1 warning, pre-existing (vendored mlx-swift Cmlx.bundle resource, not new). `swift build --package-path IntegrationTests --build-tests` — Build complete, same 1 pre-existing mlx-swift warning, 0 errors.
    - next: ready for review.
  timestamp: 2026-08-30T15:03:36.147231+00:00
- actor: claude-code
  id: 01m19k7258q3wt34jbm5k6p1rt
  text: |-
    ### commit — changed
    - evidence: cba612f feat(hosting): publish ToolContext.makeCompletionToken()
    - next: ready for review.
  timestamp: 2026-08-30T15:04:41.384333+00:00
- actor: claude-code
  id: 01m19kbz846pwdr78wdpxww8pj
  text: |
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (cba612f) — 0 findings, 0 confirmed, 0 refuted, 7 attempted, 0 failed. 3 files reviewed; 4 `.kanban/` files excluded by `.reviewignore`.
    - scope: the diffs of cba612f only — the added and modified lines.
    - public API: `ToolContext.makeCompletionToken()` returns `String`, so the signature holds no internal type. The documentation comment tells a caller inside a tool call to prefer `ToolContext.current?.completionToken`, and gives the reason: that value names the run the session already tracks.
    - next: none. Task moved to done.
  timestamp: 2026-08-30T15:07:22.244690+00:00
position_column: done
position_ordinal: ffffa780
title: Publish a way to mint a completion token
---
## What

`SessionMailbox.makeCompletionToken()` mints the identifier that names one run.
Commit `267994d` made the function internal, and card ^hqxc1tp made the actor
internal too.

Measured in this tree:

| symbol | 760ae89 | origin/main | now |
|---|---|---|---|
| `SessionMailbox` | `public actor` | `public actor` | `actor` |
| `makeCompletionToken()` | `public static func` | `static func` | `static func` |

So this break is live on `origin/main` now. It is not new. The build of the
consumer stops at an earlier error, thus the break is masked and not reported.

A package outside this one uses the function. FoundationModelsMultitool calls it in
its library, not only in its tests, at
`Sources/FoundationModelsMultitool/Capabilities/Shell/Execute.swift:218`:

```swift
let context = ToolContext.current
let commandID = context?.completionToken ?? SessionMailbox.makeCompletionToken()
```

That is the identity a shell command uses when it starts outside a session, where
`ToolContext.current` is `nil`. The consumer imports this package plain, with no
`@testable`.

## What to do

Add one public static function on `ToolContext`:

```swift
extension ToolContext {
    public static func makeCompletionToken() -> String
}
```

It calls the internal `SessionMailbox.makeCompletionToken()`.

`ToolContext` is the correct home. The caller reads `ToolContext.current` on the
line above, and uses this value when that is `nil`. So the two halves of one
decision stay on one type, and the call becomes:

```swift
let commandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()
```

Keep `SessionMailbox` internal. Keep `makeCompletionToken()` on the mailbox
internal. This is the same shape as `ToolContext.mount(_:op:as:)` from ^zgzyhsj and
`TranscriptEvent.merged(under:)` from ^cdrxcyc: put the entry point on the public
type the caller holds already.

The documentation comment must say what the token is for, and that a caller inside
a tool call must prefer `ToolContext.current?.completionToken`, because that value
names the run the session already tracks. This function is only for a caller with
no ambient context.

## Acceptance Criteria
- [x] `ToolContext.makeCompletionToken()` is public, with the documentation comment
      described above.
- [x] The package makes no other symbol public. Measure with
      `swift-symbolgraph-extract -minimum-access-level public` before and after. The
      count goes up by one.
- [x] `SessionMailbox` and `SessionMailbox.makeCompletionToken()` stay internal.
- [x] The value has the same shape as the value the mailbox mints.

## Tests
- [x] Add a test that two calls give two different tokens.
- [x] Add a test that the token has the same shape as the token the internal
      function mints.
- [x] Type-check a probe that imports the package without `@testable`, in the shape
      of the consumer's line: `ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()`.
- [x] Run `swift test`. All tests pass.
- [x] Run `swift build --package-path IntegrationTests --build-tests`. It builds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #hosting