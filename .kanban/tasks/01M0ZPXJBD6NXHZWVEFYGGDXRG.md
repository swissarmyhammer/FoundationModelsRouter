---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zqt6072w3z7y8n4e5ym17c
  text: |-
    ### severity check — `wait: false` is silently ignored, not rejected

    I read the decode path before this card gets worked, because "live code" and "broken" are different, and the fix differs.

    **It does not fail.** `ToolInvoker`'s validation layer iterates "each of the *Arguments* struct's own top-level properties" and checks that each declared property is present, well typed, and inside its guides. It walks the DECLARED properties, not the SUPPLIED keys. An extra supplied key is therefore never examined. `ExecuteArguments` declares `command`, `timeout`, `workingDirectory` and `environment` only, so `wait: false` reaches the decoder, matches nothing, and is dropped.

    So `ShellBackgroundRunner.swift:485` runs today and the integration scenario still passes.

    **What is actually wrong is worse than a compile error would be, because nothing will ever tell you.**

    1. **The snippet claims the wrong cause.** It reads as though `wait: false` is what sends the command to the background. It is not, and it never can be again: `Execute` declares its own mount, and a declared mount wins over the composition site. The command goes to the background because of that declaration. A reader — or a model shown this as an example — would copy an argument that does nothing.

    2. **`ShellBackgroundTests.swift:60` states the same false cause in prose**: "one `runCode` whose snippet calls `tools.shell.execute` with `wait: false`". That sentence records the shape of a run for a timing table, so it will be trusted.

    3. **No test can catch it.** An unknown key is silently dropped, so no assertion fails. And this file is in the nested `IntegrationTests` package, which needs real models and 12 to 15 minutes, so it is not in the ordinary `swift test`. A vestigial argument here can live indefinitely.

    **Therefore the fix is a deletion, not a rename.** Remove `wait: false` from the snippet, and correct the prose at `ShellBackgroundTests.swift:60` to say the command goes to the background because `Execute` declares a background mount. Do not replace the argument with another one.

    **One thing to check while there, which I did not:** whether `tools.shell.execute` has any other caller passing an argument `ExecuteArguments` no longer declares. The same silence hides all of them.

    Raising the general point for the board: an argument that a tool no longer declares is invisible to the type system, invisible to the validator, and invisible to the tests. `TypedMockDryRunTests.swift:126` throws on "unexpected keys" for a mock, so the idea is already in the codebase — whether the real invoker should reject unknown keys is a design question worth its own card.
  timestamp: 2026-08-26T19:12:37.895032+00:00
- actor: claude-code
  id: 01m0zr09jstdg0q9p39568th1p
  text: |-
    ### implement — changed. The card named one site; there were six.

    Commit `e066988`. The vestigial `wait: false` was the visible symptom. Chasing it found five more places describing a "block window" that `Sources/.../Capabilities/Shell/Execute.swift:37` says outright does not exist.

    **The one that mattered most was load-bearing on a number.** `ShellBackgroundTests.swift` derived its 90-second time limit like this:

    > Both runs took the `wait: false` path, so neither paid `Execute`'s own 30-second block window. A run whose model omits that argument does pay it, and the limit has to hold that run too, so the number carried forward is 59.471s + 30s ≈ 90s.

    A test limit **derived from a deleted mechanism**. Anyone re-deriving it from that comment would have reasoned from a fiction, and the file's own instruction says "Re-derive it from the machine that failed, or remove it."

    **The limit is unchanged at about 90 seconds.** The worst measured healthy run is 59.471s, and a live model sets the pace, so the headroom is still right. Only the reason is corrected — the comment now says headroom rather than a sum, and names the block window as gone. Changing the constant would be a behaviour change and does not belong on this card.

    **All six sites:**
    1. `ShellBackgroundRunner.swift` — the snippet's `wait: false`. Deleted, not renamed. `ExecuteArguments` declares `command`, `timeout`, `workingDirectory` and `environment` only.
    2. `ShellBackgroundRunner.swift` — the prompt doc said a call that waits "still goes to the background" once a 30-second window elapses. Every `execute` call goes to the background at once, because `Execute.mount` declares it.
    3. `ShellBackgroundRunner.swift` — `shellRunPlaneDeadlineSeconds` said it is "longer than `Execute`'s own 30-second block window". Now stated as headroom for a live model's pace.
    4. `ShellBackgroundRunner.swift` — `startSweptRun`'s doc said the run goes to the background "because `Execute.mount` declares a background mount **and `wait: false` answers a block window of zero**". Half true; the second half deleted.
    5. `ShellBackgroundTests.swift` — the derivation above.
    6. `IntegrationPoll.swift` — "a shell run reaches the run plane after the block window of its own call elapses". It reaches the plane when the engine tracks it.

    **Two sites deliberately kept**, because both say the window is GONE: `Execute.swift:37` and `ShellExecuteTests.swift:451`.

    **The check I said I had not done, now done.** `rg` for every `tools.shell.execute` call site: the only other one is `Execute.swift:763`, in the verb's own doc, and it passes `{ command: "swift build" }` — declared properties only. No other caller passes an argument the type does not declare.

    **Gates:** `swift build --build-tests` clean; `swift test` 1023 tests in 73 suites passed; `IntegrationTests` builds clean with `--disable-automatic-resolution`. The Router is untouched.

    **Still open, and it is a design decision rather than a cleanup.** An argument a tool no longer declares is invisible to the type system, to the validator, and to the tests. `TypedMockDryRunTests.swift:126` already throws on "unexpected keys" for a mock, so the idea exists in the codebase. Whether the real invoker should reject unknown keys needs a person; it is not this card.
  timestamp: 2026-08-26T19:15:58.169876+00:00
position_column: todo
position_ordinal: '8e80'
title: 'Integration scenarios still describe Execute''s deleted "block window", and one snippet still passes `wait: false`'
---
## What
`Execute` has no block window and no `wait` argument. `Sources/FoundationModelsMultitool/Capabilities/Shell/Execute.swift` says so in its own header: "There is no argument that selects a block window, because there is no block window." `ExecuteArguments` declares `command`, `timeout`, `workingDirectory`, and `environment`, and nothing else. `Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift` repeats it: "The `wait` argument selected a block window. There is no block window".

The integration target still describes that deleted mechanism, and one place still uses it in live code. Card ^5tsrz43 found these while it removed the `runCode` wait clock. They are a different mechanism, so they get their own card.

## The sites
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, in the prompt doc: "A call that waits instead still goes to the background — `Execute.mount` answers a 30-second block window and this command outlives it". `Execute.mount` answers `ToolMount(mode: .background, timeout: nil)`. There is no window. Keep the true point: the scenario does not depend on how the model phrased the start.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, at `shellRunPlaneDeadlineSeconds`: "Longer than `Execute`'s own 30-second block window, because a call that did not ask to skip the wait goes to the background only when that window elapses." Give the deadline a live reason.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, at `startSweptRun`: "because `Execute.mount` declares a background mount and `wait: false` answers a block window of zero". The first half is true. The second half is dead.
- [ ] `IntegrationTests/.../Support/ShellBackgroundRunner.swift`, in the snippet `startSweptRun` runs: it passes `wait: false` to `tools.shell.execute`. `ExecuteArguments` declares no such argument. THIS IS CODE, not a comment. Find out what the sandbox does with the extra key, then remove it or report what it breaks.
- [ ] `IntegrationTests/.../ShellBackgroundTests.swift`: "30-second block window. A run whose model omits that argument does pay it".
- [ ] `IntegrationTests/.../Support/IntegrationPoll.swift`: "reaches the run plane after the block window of its own call elapses".

## How
Read each sentence. Keep the true half and cut only the dead half. Write each new sentence in ASD-STE100 Simplified Technical English.

## Acceptance Criteria
- [ ] `rg -i 'block window' Sources Tests IntegrationTests docs` returns only sentences that say the block window is GONE.
- [ ] No snippet passes an argument `ExecuteArguments` does not declare.

## Tests
- [ ] `swift build --build-tests` clean, `swift test` green (baseline 1023 tests in 73 suites).
- [ ] `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` clean.
- [ ] The `wait: false` change touches a live scenario, so say in the card comments whether the scenario was run. #cleanup #docs