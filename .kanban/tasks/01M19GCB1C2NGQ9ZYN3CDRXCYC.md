---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m19hfwhwmdbepwtvzjcwc6r3
  text: |-
    Research done. Facts measured, not guessed.

    1. The break is real for the downstream package. FoundationModelsMultitool's `LiveRouterFixture.swift` imports `FoundationModelsRouter` PLAIN, with no `@testable` (line 15 of that file). `MergedTranscript` is `internal`, so that import cannot see it.

    2. This package's own `IntegrationTests` keeps compiling only because every file there uses `@testable import FoundationModelsRouter`. That is why the demotion did not show up in a build.

    3. The measurement method of ^zgzyhsj reproduces exactly. A `swift-symbolgraph-extract -minimum-access-level public` over the built module counts 620 public symbols today. Commit `799c308` recorded "619 -> 620" for ^zgzyhsj, so the counter agrees with the one that card used. The extractor needs four flags this package's build does not give by default: a versioned target triple (`arm64-apple-macosx27.0`; an unversioned one compiles for macOS 10.4 and refuses the module), `-sdk`, `-I <bin>/Modules`, and one `-Xcc -I` for each `module.modulemap` under `.build/checkouts` (without them it stops on "missing required module 'CYaml'").

    4. Precedent for the plain-import probe the card asks for: `Tests/FoundationModelsRouterTests/GuidedPublicSurfaceTests.swift`, from commit `7733619`. It sits in the ordinary unit test target, but imports the module with no `@testable`, so the compiler itself is the first assertion. `@testable` is per file, so one file is enough.

    5. A plain-import test cannot build a `TranscriptEvent` in memory: the memberwise initializer is `internal`. It must write JSONL lines to disk instead. That is closer to what the downstream consumer does anyway, and `TranscriptEventSchemaTests.mergedTranscriptDecodesMixedV1AndV2` already shows the exact line shape.

    6. `MergedTranscript.merged(under:)` reads no sidecar when none is present, so the fixture needs `transcript.jsonl` files only.
  timestamp: 2026-08-30T14:34:33.404447+00:00
- actor: claude-code
  id: 01m19hx3j1c0ca9enhntc15bbq
  text: |-
    TDD record, in order.

    RED. The two tests were written before the source change. `swift build --build-tests` stopped with `type 'TranscriptEvent' has no member 'merged'` at MergedTranscriptPublicSurfaceTests.swift:63, plus three key-path errors that follow from it. The failure is the missing feature, not a typo.

    GREEN. The extension was added, and both tests pass.

    Two notes on the tests, so a later reader does not weaken them.

    1. `MergedTranscriptPublicSurfaceTests` writes each session's own file in the REVERSE of the merged order, and deals the events round-robin between two sessions. A merge that only concatenated its files, in the order it read their lines, cannot pass. That is what makes the order assertion load-bearing.

    2. `publicEntryPointMatchesTheInternalMerge` in `MergedAndRedactionTests` compares the two readers directly. Two equal empty arrays would satisfy that comparison and prove nothing, so the test also asserts the count against the number of events it recorded.

    One decision to state. The doc comment names `MergedTranscriptError` and `RecordingSchemaVersionError` as plain code text, not as DocC links. Both types are internal, and commit `5379087` set that rule: a doc comment refers to an internal symbol in single backticks with the word "internal", never as a ``link``. Both error types stay internal, as the card says; no measurement showed a caller must tell one failure apart from another.

    The downstream call site is served. FoundationModelsMultitool writes
    `try MergedTranscript.merged(under: recordingsDir.appendingPathComponent(router.id.description))`
    and assigns the result to `[TranscriptEvent]`. It becomes `try TranscriptEvent.merged(under:)` with the same argument and the same result type. `Router.id` is already `public nonisolated let id: ULID`, so nothing else in that expression is out of reach. No file in that repository was changed.
  timestamp: 2026-08-30T14:41:46.561476+00:00
- actor: claude-code
  id: 01m19hxchcaz7vafqffj8xxsgj
  text: |-
    ### implement — changed
    - evidence: 3 files. Source: Sources/FoundationModelsRouter/Recording/MergedTranscript.swift (one `extension TranscriptEvent` holding the public `merged(under:)`, plus a line on the internal enum naming that entry point). Tests: Tests/FoundationModelsRouterTests/MergedTranscriptPublicSurfaceTests.swift (new, plain import, 1 test), Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift (+1 test).
    - public surface: 620 -> 621 symbols. The diff of the two symbol lists holds exactly one added line, `s:22FoundationModelsRouter15TranscriptEventV6merged5underSayACG0A03URLV_tKFZ`, and no removed line. Measured with `swift-symbolgraph-extract -minimum-access-level public` over the built module, before the change and after it.
    - `MergedTranscript` and `MergedTranscript.merged(under:)` are unchanged and still internal.
    - `swift test`: 1124 tests in 122 suites passed, plus 83 tests in 10 suites in the evals target. 0 failures. The 2 known issues are the pre-existing `RealModelHarness` and `BoundedWait` ones.
    - `swift build --package-path IntegrationTests --build-tests`: Build complete. The one warning is SwiftPM's pre-existing `missing creator for mutated node` on the mlx-swift bundle, which no change here touches.
    - next: /review
  timestamp: 2026-08-30T14:41:55.756170+00:00
- actor: claude-code
  id: 01m19j9z1mhw82wws0c8d18qem
  text: |-
    ### review — clean
    - evidence: `review sha HEAD~1..HEAD` (commit 1680422) — 0 findings, 0 confirmed, 0 refuted, 7 validators attempted, 0 failed. 3 source files reviewed; 10 `.kanban/` files excluded by `.reviewignore`.
    - next: task moved to done.
  timestamp: 2026-08-30T14:48:47.924283+00:00
- actor: claude-code
  id: 01m19jajjtjj51km3dkdphh15g
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — 3 files; Sources/FoundationModelsRouter/Recording/MergedTranscript.swift, a new Tests/FoundationModelsRouterTests/MergedTranscriptPublicSurfaceTests.swift, Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift
    - test: green — `swift test`, 1124 tests in 122 suites + 83 tests in 10 suites, 0 failed, 0 skipped; `swift build --package-path IntegrationTests --build-tests` builds
    - commit: 1680422 — feat(recording): publish TranscriptEvent.merged(under:) as a read API
    - review: clean — 0 findings, 7 validators, task moved to done

    The public surface goes from 620 to 621 symbols, measured with
    `swift-symbolgraph-extract -minimum-access-level public`. The diff holds one added
    mangled name and none removed. The 620 baseline agrees with the count that ^zgzyhsj
    recorded, so both cards used the same counter.

    The new test imports the module with no `@testable`, so the compiler itself proves an
    outside caller can make the call. It writes each session file in the reverse of the
    merged order, so a plain concatenation cannot pass it.
  timestamp: 2026-08-30T14:49:07.930622+00:00
position_column: done
position_ordinal: ffffa680
title: Publish a read API for a merged transcript
---
## What

Commit `267994d` "refactor(api): demote the mistakenly public Session and Recording
plumbing" made two symbols internal:

- `MergedTranscript` — Sources/FoundationModelsRouter/Recording/MergedTranscript.swift:38
- `merged(under:)` — the same file, line 55

Measured in this tree: at `267994d^` both carried `public`. Now neither does. That
commit is on `origin/main`, so this break is live, and not only local.

A package outside this one uses the function. FoundationModelsMultitool calls it at
`IntegrationTests/Tests/FoundationModelsMultitoolIntegrationTests/Support/LiveRouterFixture.swift:583`,
to read the recordings of a live router and to assert on the event stream of a real
run. It is the only consumer. It is in a nested integration package, so it did not
show in the build failure that ^zgzyhsj repaired.

Nothing public replaces it. There is no other public way to read a merged transcript
from disk.

## What to do

Add one public static function on `TranscriptEvent`:

```swift
extension TranscriptEvent {
    public static func merged(under routerDirectory: URL) throws -> [TranscriptEvent]
}
```

It calls the internal `MergedTranscript.merged(under:)`.

Do not make `MergedTranscript` public again. Two symbols become public if you do.
This adds one, because `TranscriptEvent` is public already
(Sources/FoundationModelsRouter/Recording/TranscriptEvent.swift:11), and it is the
element type of the result. This is the same shape as `ToolContext.mount(_:op:as:)`
from ^zgzyhsj: put the entry point on the public type the caller holds already.

`MergedTranscriptError` stays internal. Swift errors are untyped, so a public
function throws it correctly. Make it public only if a measurement shows a caller
must tell one failure from another; write what the measurement was.

## Acceptance Criteria
- [x] `TranscriptEvent.merged(under:)` is public, and its documentation comment says
      it is the supported way to read a merged transcript from disk.
- [x] The package makes no other symbol public. Compare the public surface before the
      change and after it with
      `swift-symbolgraph-extract -minimum-access-level public`. The count goes up by
      one.
- [x] `MergedTranscript` and `MergedTranscript.merged(under:)` stay internal.
- [x] The result is the same as the internal function gives, in the same order.

## Tests
- [x] Add a test that reads a merged transcript through the new public function.
- [x] The test asserts the order of the events, and that events from more than one
      session under the router directory are merged.
- [x] Type-check a probe that imports the package without `@testable`, to prove an
      outside caller can make the call.
- [x] Run `swift test`. All tests pass.
- [x] Run `swift build --package-path IntegrationTests --build-tests`. It builds. Do
      not use that command without `--build-tests`, because that command builds
      nothing.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #recording