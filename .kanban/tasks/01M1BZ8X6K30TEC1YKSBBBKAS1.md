---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1bzx9w3nemxr5njvqyz1xkt
  text: |-
    ### The four call sites, the lifetime requirement, and a correction

    #### Correction to the card's justification

    The card implies the sink variant was the smaller of two shapes that both worked, and
    that `detached(tool:op:)` from ^h3tjfse would also have served. The consumer says the
    opposite, reading the code path: **detached would have fixed none of the four.**

    The reason is a DOUBLE re-stamp. An event a mounted tool posts is re-stamped twice:

    1. the run's own `ToolContext` re-stamps it onto the RUN's token, then
    2. `MountedRunUpstreamSink` calls `post` on the MOUNTING context, which re-stamps it
       again onto the mounting context's token.

    A detached context is still a mounting context, so step 2 still lands on it and the
    run's own identity is still gone. Detached fixes the LEVEL — a stub sits one run deep,
    detached sits at the top — but every one of these four assertions needs the value from
    BEFORE step 2.

    The old fixtures passed the sink directly to `ToolMounting.makeWrapped`, so step 2
    never happened. That is what `postingTo:` restores.

    So the record should read: the sink variant is not the smaller of two working shapes,
    it is the only shape that works. VERIFY THIS rather than take it — the consumer says
    plainly it is read from the code and not measured. Print a correlation through both
    paths and settle it.

    #### The four call sites this must serve

    ```swift
    // MCPServerCallTests:400 — two concurrent probes, each its own sink.
    let engine = context.mount(probe, as: .synchronous, postingTo: sink)

    // HostAndEmitterTests:82 — a snippet that backgrounds, inner tool posts
    // progress AFTER the envelope came back.
    let mounted = context.mount(MultiTool(registry: registry), as: .synchronous, postingTo: sink)

    // SuspendedContextTests:138 — background mount, terminal counted.
    let mounted = context.mount(multiTool, as: ToolMount(mode: .background, timeout: nil), postingTo: sink)

    // ShellSessionSweepTests:263 — background shell run, swept by close().
    let mounted = context.mount(tool, as: ToolMount(mode: .background, timeout: nil), postingTo: sink)
    ```

    #### The lifetime requirement, which is the real trap

    THREE of the four background the run. A background mount returns its pending envelope
    at once and the body continues behind it, so the caller-supplied sink must keep
    receiving AFTER `call(arguments:)` has returned — the progress events, and then the
    terminal, possibly seconds later. `ShellSessionSweepTests` is the extreme: its terminal
    arrives only when `close()` sweeps the run, after everything else in the test.

    So the sink must be held per RUN, not per call, and must not be released when the call
    returns.

    An implementation that captures it per call passes the synchronous case and fails all
    three background ones. A test that covers only `.synchronous` would report green over
    exactly that defect. **A background-mount test is mandatory**, and it must assert an
    event delivered after the mounted call returned.

    #### The validation plan

    The consumer offered to run all four against a branch before this lands on `main`.
    Take it. Push to a branch, have them pin both their packages at that revision and run
    the four, then land on `main` once they report. One round trip rather than
    push-fail-fix-push, and neither side has been able to trust a reading today.
  timestamp: 2026-08-31T13:25:01.955569+00:00
- actor: claude-code
  id: 01m1c05q21q28g5b9g1gtmr4vg
  text: |-
    ### Research — picked up, before the first edit

    **Baseline surface, measured.** `python3 scripts/symboldiff.py FoundationModelsRouter . HEAD` returns exit 4 and measures nothing:

    ```
    extracting FoundationModelsRouter at HEAD (475befb)
    no FoundationModelsRouter.symbols.json under ./.build/symboldiff/<c>/symbols: the
    extraction wrote nothing for that module, so its surface was never measured
    ```

    Cause, found: the script joins `PACKAGE_REPO` into the graph directory, so a repo given as `.` makes `-emit-symbol-graph-dir` a RELATIVE path. SwiftPM runs the compiler with the worktree as its working directory, so the 71 graph files land at `.build/symboldiff/<c>/source/.build/symboldiff/<c>/symbols/` — inside the worktree the script then removes. Measured: `find .build/symboldiff/<c> -name '*.symbols.json' | wc -l` = 71, none of them where the script looks.

    Work-around used, no script change: give the repo as an absolute path.

    ```
    python3 scripts/symboldiff.py FoundationModelsRouter /Users/wballard/github/swissarmyhammer/FoundationModelsRouter HEAD
    ```

    That returns exit 0. **Baseline at HEAD (475befb): 650 declarations.** Not the 623 the card names — HEAD has moved since the card was written (`377c1ee feat(router): make default protocol implementations public` is one of the commits between). The card's acceptance is a DELTA of exactly two symbols, and the delta is what this run will measure. A separate card is due for the relative-path defect.

    **The public surface has no route to a `ToolContext`.** Measured off the same run: `ToolContext` publishes no initializer, and `SessionMailbox` is not public at all. So a test with a plain `import FoundationModelsRouter` cannot build a context by hand; the one route is `ToolContext.current` inside a running tool. The tests therefore drive a scripted session (`ScriptedSessionFixture`) and do every mount inside the host tool's `call`.

    **`OperationEventSink.post(invocation:)` already carries a public blanket default** in FoundationModelsExtras, so a caller-written sink implements `post(event:)` alone.

    **The double re-stamp the consumer reads from the code is real, read here too, and is going under test rather than taken:** `ToolRun` binds the run's context over `RunEventFunnel`, whose `upstream` is whatever sink the mount was given. The default overload gives it `MountedRunUpstreamSink`, which calls `post` on the MOUNTING context — a second stamp. A caller-supplied sink is the `upstream` itself, so the second stamp never happens.

    **The lifetime requirement is structural, and the background test will hold it.** `BackgroundToolRunner` stores the sink and hands it to each `ToolRun`, whose `RunEventFunnel` holds it as `upstream` for the life of the RUN. Ordering measured from the code: `mailbox.wait(...)` cannot report `.settled` before the terminal has been delivered upstream, because the settling task awaits `run.execute`, which awaits `funnel.settleRun`, which awaits the upstream delivery. So the background test needs no poll and no sleep: it snapshots the sink at the moment `call(arguments:)` returns, opens the gate, awaits settlement, and reads the terminal that arrived after the call had already returned.
  timestamp: 2026-08-31T13:29:37.601435+00:00
- actor: claude-code
  id: 01m1c1dj3k42avr67d4dpwrgn1
  text: |-
    ### The double re-stamp is settled by measurement, not by reading

    The consumer said plainly that they read it from the code and did not measure it. It is
    measured now, and it is TRUE. One run of `RunIdentityTool` was mounted twice on ONE
    context, one call apart, with the overload as the only difference. Both routes end in
    the same caller-supplied sink, so the two correlations sit side by side:

    ```
    MEASURED mounting run token        = 01M1C18EVGG2V2C8097E4MC4EF
    MEASURED default-mounted own token = 01M1C18EVGR134C1ZQP9MJ9RQH
    MEASURED default-mounted event id  = 01M1C18EVGG2V2C8097E4MC4EF   <- the mounting run
    MEASURED sink-mounted own token    = 01M1C18EVG907VSAMK7J2MN6G6
    MEASURED sink-mounted event id     = 01M1C18EVG907VSAMK7J2MN6G6   <- its own
    ```

    The default-mounted run minted `...MJ9RQH` for itself and the sink never saw that
    token: the second stamp replaced it with the mounting run's `...4MC4EF`. The
    sink-mounted run kept its own. So the record reads as the consumer asked: the sink
    variant is not the smaller of two working shapes, it is the only shape that works, and
    a detached context would have fixed none of the four call sites.

    The prints above were temporary. The permanent form is
    `theDefaultOverloadRestampsWhereTheSinkOverloadDoesNot`, which asserts all four facts —
    that each correlation IS what it should be, and that each is NOT the other.

    ### One decision the card should record: the existing overload's BODY now delegates

    The card says "Do not change the existing one". Its declaration, its defaults and its
    behavior are untouched, and it still re-stamps. Its body is now one line:

    ```swift
    mount(tool, op: op, as: configuration, postingTo: MountedRunUpstreamSink(context: self))
    ```

    The alternative was to copy the twelve-line body — the `makeWrapped` call, the
    conditional cast and the four-line unreachable-fallback comment — into the new
    overload. That is a near-verbatim copy differing by one argument, which the
    `duplication` validator names as "one function with an argument", and it is exactly the
    shape that drifts. The delegation leaves one body, and it is the body the new overload
    holds. `swift test` proves the default route still re-stamps.

    ### One lint measurement worth stating rather than hiding

    `swiftlint lint` over the three touched files reports:

    - `file_length`: the new test file is 465 lines against a 400-line default. Left as it
      stands. There is no `.swiftlint.yml` in this repository, so that is swiftlint's own
      default rather than a project setting; swiftlint is not a CI gate here (it reports
      `identifier_name` on the pre-existing `op` parameter at four untouched sites, which
      would already fail the build were it one); the test target's own files run to 900+
      lines; and `file_length` is not among the rules the review validators carry. The card
      asks for both re-stamp facts in ONE file, so splitting the tests is not available;
      splitting the fixtures out would only move lines behind a second file.
    - `identifier_name` on `op`: pre-existing at four sites in `ToolContext.swift`, and the
      new overload carries the same parameter because the card specifies that signature and
      because `op` is this package's public vocabulary (`ToolContext.op`, `BackgroundRun.op`,
      `ToolInvocationRecord.op`). Renaming it would break the public surface.

    `swift-format lint` reports indentation against its own 2-space default over untouched
    pre-existing lines; the repository indents with 4 and carries no `swift-format`
    configuration, so that output measures the default and not this change.
  timestamp: 2026-08-31T13:51:23.251436+00:00
- actor: claude-code
  id: 01m1c1e36tes7111v7mk815dfd
  text: |-
    ### implement — changed

    - files: 3 — `Sources/FoundationModelsRouter/Hosting/ToolContext.swift`,
      `Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift`,
      `Tests/FoundationModelsRouterTests/ToolContextMountSinkPublicSurfaceTests.swift` (new)
    - tdd: the new file was written first and watched fail to COMPILE, on the two symbols
      the card names — `cannot find type 'OperationEventSink' in scope` and
      `extra argument 'postingTo' in call` at five sites. Compilation alone is a weak red
      for the four behavioral assertions, so the production path was then mutated (the new
      overload made to wrap `sink` in `MountedRunUpstreamSink`) and all four tests went red
      against the correct signature. The mutation was reverted and all four pass.
    - tests: `swift test` -> exit 0, 1136 tests in 126 suites plus 83 tests in 10 suites,
      0 failures, 2 pre-existing known issues (`RealModelHarness`, `BoundedWait`). The four
      new tests are `callerSuppliedSinkSeesTheMountedRunsOwnCorrelation`,
      `theDefaultOverloadRestampsWhereTheSinkOverloadDoesNot`,
      `twoConcurrentRunsAreDistinguishableByCorrelation`,
      `backgroundMountKeepsPostingAfterTheCallReturned`.
    - integration: `swift build --package-path IntegrationTests --build-tests` -> exit 0.
    - surface, measured: **650 -> 652**, `removed: 0  changed: 0  added: 2`, exit 0. The two
      rows are `OperationEventSink (swift.typealias)` and
      `ToolContext.mount(_:op:as:postingTo:) (swift.method)` and nothing else. The card's
      623 -> 625 was a stale baseline: HEAD moved between writing and doing (475befb), and
      the DELTA the card asks for is what was measured.
    - the background case: mounted `as: ToolMount(mode: .background, timeout: nil)`, the
      test snapshots the sink at the instant `call(arguments:)` returns and asserts NO
      terminal there, then releases the run at a barrier and asserts the terminal arrives —
      carrying the run's own token. The absence assertion is not read blind: it sits beside
      two content assertions on the same snapshot (the run plane tracked one run; the
      launch's own progress event had already reached the sink), so a dead read would fail
      rather than pass.
    - no hang route: the suite carries `.timeLimit(.minutes(1))`, and every wait is on an
      event or a barrier rather than inside a `for await` body. No `streamSessionEvents()`
      is used anywhere; the caller's sink is the direct route.
    - next: `/review`. Nothing is committed and nothing is pushed — this goes to a branch
      for the consumer to validate the four call sites against before it nears `main`.
  timestamp: 2026-08-31T13:51:40.762971+00:00
- actor: claude-code
  id: 01m1c1rrvbyr48eexbh5vj0y1b
  text: |-
    ### review — clean

    - evidence: `review sha HEAD~1..HEAD` on `d576a72`, branch `mount-posting-to`. findings 0,
      confirmed 0, refuted 0. 7 validators attempted, 0 failed, 0 skipped. 3 source files
      reviewed; 6 `.kanban/` files excluded by `.reviewignore`.
    - files reviewed: `Sources/FoundationModelsRouter/Hosting/ToolContext.swift`,
      `Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift`,
      `Tests/FoundationModelsRouterTests/ToolContextMountSinkPublicSurfaceTests.swift`.
    - the validators that matched the Swift diff: `swift` (11 rules — casing, naming
      clarity, doc parameter naming, fluent usage, access control, optionals, concurrency),
      `code-hygiene` (30 rules — includes `missing-docs-swift` and `function-length-swift`),
      `completeness` (4 rules, with the `public-surface` and `clone-siblings` probes),
      `duplication`, `reuse`, `test-integrity`, `code-security`. Each one gave zero findings.
    - the new public surface: the `swift` and `code-hygiene` validators cover the naming and
      the documentation of a public API. Neither reported a defect on the two new symbols.
    - the delegation of the three-argument overload: the `completeness` validator, with its
      `public-surface` and `clone-siblings` probes, and the `duplication` validator cover a
      refactor of this shape. Neither reported a defect.
    - the `file_length` question, measured rather than judged: no validator in the fleet
      carries a file-length rule. `grep -ril 'file_length' /Users/wballard/.validators/`
      returns nothing; `code-hygiene` carries `function-length-swift.md` and no file-length
      equivalent. The repository also holds no `.swiftlint.yml`, `.swiftformat`,
      `.swift-format` or `.swift-version`, so the 400-line limit is swiftlint's own default
      and not a project setting. swiftlint gives no review finding here, so there is no
      finding to stand.
    - no prior `## Review Findings` section is on this card. This is the first review pass,
      and it is clean, so no dated section was appended.
    - next: the card is in `done`. The commit is on the branch `mount-posting-to` and is not
      on `main`. The consumer validation of the four call sites, which comment
      `01m1bzx9w3nemxr5njvqyz1xkt` asks for, is still open before this goes to `main`.
  timestamp: 2026-08-31T13:57:30.603395+00:00
- actor: claude-code
  id: 01m1c1takjd0g2ctyjv7yay8wk
  text: |-
    ### finish iteration 1 — clean, but held on a branch

    - implement: changed — 3 files; the new overload, the public typealias, and a new test file with 4 tests
    - test: green — `swift test` 1136 tests in 126 suites + 83 tests in 10 suites, 0 failed; `swift build --package-path IntegrationTests --build-tests` builds
    - commit: d576a72 — feat(hosting): let a caller supply the sink when mounting on a ToolContext
    - review: clean — 0 findings, 7 validators

    **NOT ON `main`, and that is deliberate.** The commit is on branch
    `mount-posting-to` at `d576a72`. `main` is still `475befb`.

    The consumer is validating all four of its blocked assertions against that
    revision before it lands. The whole point of this card is those four call sites, and
    this package cannot run them — three of them background a run and one gets its
    terminal only when `close()` sweeps. One round trip against the real call sites is
    worth more than push-fail-fix-push, and I told the consumer nothing would go near
    `main` until it reported.

    The card is code-complete. It is not finished.

    ### What was measured rather than assumed

    The double re-stamp, which is the card's whole justification. One tool, mounted twice
    on one context, one call apart:

    ```
    mounting run token        = 01M1C18EVGG2V2C8097E4MC4EF
    default-mounted own token = 01M1C18EVGR134C1ZQP9MJ9RQH
    default-mounted event id  = 01M1C18EVGG2V2C8097E4MC4EF   <- the mounting run
    sink-mounted own token    = 01M1C18EVG907VSAMK7J2MN6G6
    sink-mounted event id     = 01M1C18EVG907VSAMK7J2MN6G6   <- its own
    ```

    So the consumer's reading was right and my earlier summary was wrong: a detached
    context would have fixed NONE of the four, because the second stamp lands on it
    whatever its level. `postingTo:` is the only shape that works, not the smaller of two.

    Surface measured 650 to 652 — removed 0, changed 0, added 2. The card's 623/625 was a
    stale baseline; `main` moved to 475befb after the card was written.

    The tests were mutation-tested. A compile failure is a weak red for a behavioural
    claim, so the production path was mutated to wrap the caller's sink again, and all
    four went red against the correct signature before the mutation was reverted.

    ### The gap in my own evidence

    The lifetime test proves the sink receives after `call(arguments:)` returns, using a
    barrier this package controls. It does NOT reproduce the consumer's sweep case, where
    the terminal arrives only at `close()`. That path could not be built here. If
    `ShellSessionSweepTests:263` fails on the branch, that is a real gap in this change
    and not a fixture defect.

    ### Remaining to finish this card

    1. The consumer reports on the four.
    2. Fix anything that failed, on the branch.
    3. Merge to `main`.
    4. CI green.
  timestamp: 2026-08-31T13:58:21.554473+00:00
position_column: done
position_ordinal: ffffac80
title: Let a caller supply the sink when mounting on a ToolContext
---
## What

`ToolContext.mount(_:op:as:)` (card ^zgzyhsj) hardcodes its upstream sink. That sink,
the private `MountedRunUpstreamSink`, forwards through `ToolContext.post(_:)`, and
`post` re-stamps:

```swift
/// Posts `event` upstream, re-stamped with this run's ``tool``, ``op``, and
/// ``completionToken``. Only `kind`, `detail`, `outcome`, and `elicitation`
/// survive the re-stamp.
```

So every event a mounted run posts reaches the outbox on the MOUNTING run's
correlation, and the mounted run's own token is not visible outside the run plane.

The re-stamp is right, and it stays the default. The defect is that `mount` decides it
for the caller. `ToolMounting.makeWrapped` took a sink as an argument, so a caller
could hand in its own and observe the raw per-run correlation. ^zgzyhsj replaced that
with a facade that chose one sink, and the choice was made because the one consumer
then in view wanted the re-stamp. That narrowed a capability while appearing only to
narrow surface.

Measured by the consumer, one scripted background run mounted through the facade:

```
outer context completionToken = 01M1BYNARFGAGYBN42VDH26D5D
scripted run  completionToken = 01M1BYNARGPQG5SKHKG0MRYQHA
journal .progress   correlationID = 01M1BYNARFGAGYBN42VDH26D5D   <- outer
journal .completed  correlationID = 01M1BYNARFGAGYBN42VDH26D5D   <- outer
```

Four of the consumer's assertions cannot be written without the raw view. The sharpest
is "two concurrent calls to the same tool produce events distinguishable by
correlationID": mounted on one context, both collapse to that context's token, so the
question cannot be asked at all.

## What to do

Add ONE overload beside the existing method. Do not change the existing one.

```swift
extension ToolContext {
    public func mount<T: Tool>(
        _ tool: T,
        op: String? = nil,
        as configuration: ToolMount = .synchronous,
        postingTo sink: any OperationEventSink
    ) -> any Tool<T.Arguments, T.Output>
}
```

It passes `sink` straight through to `ToolMounting.makeWrapped(tool:inheriting:sink:...)`
in place of `MountedRunUpstreamSink`. Everything else is identical: the same mount
arbitration, the same decorator dispatch, the same context binding.

The three-argument overload keeps `MountedRunUpstreamSink` and stays the shape a host
should reach for. The re-stamped view is the default; the raw view is opt-in.

## The typealias

`OperationEventSink` is internal, at Hosting/OperationVocabulary.swift:23. A public
signature naming it needs it public.

Make it public. It is the ONE non-public line in that file — every other typealias
there is already public, including `OperationEvent`, `OperationEventKind`,
`OperationOutcome` and `ToolInvocationRecord`. Publishing it removes an inconsistency
rather than adding a symbol for its own sake, and it lets a caller write the
conformance without importing FoundationModelsExtras.

Measure it: the surface should go from 623 to 625, the method and the typealias, and
nothing else.

## Documentation

Both overloads need a comment that says which correlation the caller will see, because
that is the whole difference between them and it is invisible at the call site:

- The default: events reach the outbox on the MOUNTING run's correlation. This is what
  an application wants — the operation the session issued is the one the outbox names.
- The `postingTo:` form: the caller's sink observes each run's OWN `completionToken` as
  the `correlationID`, unstamped. Say what this is for — telling concurrent runs apart,
  and asserting a run's own identity — and say that a host that only wants to know what
  happened should use the default.

## Acceptance Criteria
- [x] `mount(_:op:as:postingTo:)` is public and passes the sink through unchanged.
- [x] The existing three-argument overload is unchanged and still re-stamps.
- [x] `OperationEventSink` is public.
- [x] The surface goes 623 to 625, measured, with those two symbols and no others.
- [x] A run mounted with a caller-supplied sink posts events carrying its OWN
      completionToken.
- [x] The same run mounted through the default overload posts events carrying the
      MOUNTING context's token. Both facts in one test file, so the difference is
      legible side by side.
- [x] Two concurrent runs mounted with a caller-supplied sink are distinguishable by
      correlationID. This is the consumer assertion that cannot be written today.
- [x] A background mount keeps posting to the caller's sink after `call(arguments:)`
      has returned: the sink is held per RUN, not per call.

## Tests
- [x] Add tests for each criterion above. Plain `import FoundationModelsRouter`, no
      `@testable`, so the compiler proves an outside caller can write them.
- [x] Run `swift test`. All tests pass.
- [x] Run `swift build --package-path IntegrationTests --build-tests`. It builds.

## Note on the extractor

Use the SwiftPM route: `swift build -Xswiftc -emit-symbol-graph -Xswiftc
-emit-symbol-graph-dir -Xswiftc <dir>`. `scripts/symboldiff.py` now does this; run it
over `HEAD` before and after rather than hand-building flags. The surface is the SUM of
`<M>.symbols.json` and every `<M>@*.symbols.json`.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #hosting