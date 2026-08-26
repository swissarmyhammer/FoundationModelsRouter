---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zdw4mjx56e5vsqa7q3kj5e
  text: |-
    ### scope survey — read-only, taken at Multitool 1b5cf2d

    Measured with `rg` over `Sources`, `Tests` and `IntegrationTests`, with `.build` excluded. This tells the implement step where the work is, so it does not measure again.

    **`detach` — zero sites.** The rename is complete in code. Nothing to do.

    **`waitSeconds` — 4 sites, and 3 of them are correct as they are.**
    - `Sources/FoundationModelsMultitool/MultiTool.swift:224` — prose that says `waitSeconds` is GONE and gives the reason. Keep. It is the record of the removal.
    - `Tests/FoundationModelsMultitoolTests/MultiToolExecutionTests.swift:29` — `#expect(!schema.contains("waitSeconds"))`. Keep. This is the guard that stops the parameter from coming back.
    - `IntegrationTests/.../Support/ScenarioRunner.swift:270` — quotes an `eventplan.md` section title word for word. Do not edit a quotation. Correct `eventplan.md` first, or leave it.
    - `Sources/FoundationModelsMultitool/Capabilities/Shell/GetLines.swift:17` — **this one needs a decision.** It says "the sibling carries a `waitSeconds` long-poll for that". Confirm the sibling verb still has such a parameter. If it does not, the sentence is false and must change.

    **`Parked`/`parked` — 45 sites in 7 files, all under `IntegrationTests`.** This is the real work of this card. The identifiers, at `Support/ShellElevationRunner.swift`:
    - `:288` `struct ParkedShellRun: Sendable, CustomStringConvertible`
    - `:316` `var parkedRun: ParkedShellRun?`
    - `:368` `var parked: BackgroundRun?`
    - `:373` `guard let parked else { return observation }`

    File counts: `ShellElevationRunner.swift` 21, `ScenarioRunner.swift` 10, `LiveRouterFixture.swift` 4, `NestedGenerationProbeTests.swift` 4, `InBandCollectionCanaryTests.swift` 4, `Fixtures/ScenarioTools.swift` 1, `Fixtures/ScenarioCallLog.swift` 1.

    A background run is in motion. "Parked" says it stopped, which is the opposite. Use `BackgroundShellRun`, `backgroundRun` and `background`.
  timestamp: 2026-08-26T16:18:56.274840+00:00
- actor: claude-code
  id: 01m0zdxgqvaczs5a1x5d5zntx8
  text: |-
    ### correction to the scope survey — `GetLines.swift:17` is CORRECT, do not change it

    My earlier survey said `Sources/FoundationModelsMultitool/Capabilities/Shell/GetLines.swift:17` "needs a decision" because it names a `waitSeconds` long-poll. That was my error. I read "the sibling" as a sibling verb in this package. It is not.

    Lines 3 and 4 of that same file say what "the sibling" is: `../FoundationModelsShelltool/Sources/ShellTool/Operations/GetLines.swift`. That is a different repository, and the file is present on this machine. It really does carry the parameter:
    - `Sources/ShellTool/Operations/GetLines.swift:64` — `var waitSeconds: Int?`
    - `:87` and `:88` — a negative value returns the corrective "waitSeconds must be non-negative"
    - `:92` — the value makes the long-poll deadline

    So the sentence is a true statement about another package. **Do not edit it.** The paragraph is doing useful work: it says why this verb has no long-poll of its own, and where the wait lives instead (`WaitTool` and the `wait(token, seconds)` sandbox global).

    `waitSeconds` in THIS package is fully gone. All 4 remaining sites are correct as they are:
    - `MultiTool.swift:224` — the record of the removal.
    - `MultiToolExecutionTests.swift:29` — the guard that stops it coming back.
    - `ScenarioRunner.swift:270` — a word-for-word quotation of an `eventplan.md` section title.
    - `GetLines.swift:17` — a true cross-reference to another repository.

    The work of this card is therefore only the `Parked` -> `Background` rename in the 7 `IntegrationTests` files.
  timestamp: 2026-08-26T16:19:41.435968+00:00
- actor: claude-code
  id: 01m0zeazqh6zmj7cwzkycbb8ya
  text: |-
    ### the 45 sites, split into the mechanical part and the part that needs judgment

    Full list dumped to the scratchpad as `t73m7pw_parked_sites.txt`. The split:

    **Mechanical — 13 sites, 3 files.** `ParkedShellRun` and `parkedRun`, in
    `Support/ShellElevationRunner.swift`, `Support/ScenarioRunner.swift` and
    `InBandCollectionCanaryTests.swift`. Rename to `BackgroundShellRun` and
    `backgroundRun`.

    **Mechanical, one scope.** The local `parked` in
    `Support/ShellElevationRunner.swift` lines 368 to 376: the declaration
    `var parked: BackgroundRun?`, its assignment, the `guard let parked`, and the
    four reads at 375 and 376. Rename to `background`.

    **One diagnostic string key.** `ShellElevationRunner.swift:254` prints
    `"parked=\(plane.parkedRun?.description ?? "none") "`. The key must become
    `background=`, not only the property.

    **A point that settles the naming.** Line 370 already reads
    `parked = await context.backgroundRuns().first { ... }`. The local is called
    `parked` while the Router API it calls is `backgroundRuns()`. The code is
    arguing against its own name.

    **Judgment — about 30 prose sites.** Do NOT run a blind substitution over
    these. "Parked" is used in more than one grammatical role, and two of them are
    correct English that must stay:
    - `ShellElevationRunner.swift:746` "the parked shell run" — the design word.
      Change it.
    - `ShellElevationRunner.swift:782` "the run still parked at teardown" — the
      design word. Change it.
    - `ScenarioRunner.swift:1579` "the nested `respond` parked" — read this one
      before you change it. If it describes a call that truly stopped and waits,
      "parked" is correct English and must stay. If it describes a run in motion,
      it is the same defect.

    The rule: a background run is in motion, so "parked" is wrong for it. A thing
    that really did stop and wait may keep the word.
  timestamp: 2026-08-26T16:27:02.769665+00:00
depends_on:
- 01M0XGSGZHRNAFH48D4DMTTQZ1
position_column: todo
position_ordinal: '8880'
title: 'Multitool: purge waitSeconds from sources and tests'
---
## What
Cross-repo task in `../FoundationModelsMultitool`. Second of three. Remove every `waitSeconds` parameter, argument, and mention from `Sources/`, `Tests/`, and `IntegrationTests/` (12 files) — the Router engine no longer has it. Keep `timeout` pass-through where a caller bounds work. Rename the "Elevation"-vocabulary test files (`IntegrationTests/Tests/FoundationModelsMultitoolIntegrationTests/ElevationTests.swift`, `Support/ShellElevationRunner.swift`) to the background vocabulary, and update the pending-envelope test cases: they become always-handle cases.

## Acceptance Criteria
- [ ] `rg 'waitSeconds' Sources Tests IntegrationTests` in FoundationModelsMultitool returns no match.
- [ ] `rg -il 'elevat' Sources Tests IntegrationTests` returns no match.
- [ ] The Multitool test suite and IntegrationTests are green.

## Tests
- [ ] Updated existing suites; no new behavior. Run `swift test` in `../FoundationModelsMultitool` — green.

## Workflow
- Use `/tdd` — run the suites before and after each file group. #long-running #cleanup