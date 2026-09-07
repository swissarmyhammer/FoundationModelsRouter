---
depends_on:
- 01M1XWYD9XFBXWGPP11H59152D
position_column: todo
position_ordinal: '8180'
title: Add a cancelled phase to ResolutionProgress
---
## What

`ResolutionProgress` has no phase for a cancelled resolve. Add one.

1. `ResolutionProgress.Phase` (Sources/FoundationModelsRouter/Resolution/ResolutionProgress.swift:74-85) has the cases `sizing`, `downloading`, `loading`, `ready` and `failed(String)`. The `phase` property is at ResolutionProgress.swift:88.

2. Thus a host that binds to `ResolutionProgress` cannot tell a cancelled resolve from a failed resolve. `failed(String)` shows a diagnostic message for an operation that the user stopped.

3. Add a `cancelled` case to `Phase`. `runResolve` (Sources/FoundationModelsRouter/Router.swift:254) sets `.cancelled` when it throws `CancellationError`, and does not set `.failed`.

4. `Phase` is `public` and `Equatable`. The new case is thus an addition to the public API. Write a doc comment on the case, because a public declaration must have one.

5. Each `switch` over `Phase` in the package must have an arm for the new case. Do not add a `default` arm, because the compiler must find the next missing arm.

## Test shape

- A test cancels a resolve and shows that the phase is `.cancelled` and not `.failed`.
- A test makes a resolve fail and shows that the phase stays `.failed(String)` with its message.
- A test shows that a resolve that completes stays `.ready`.

## Why

FoundationModelsACPAgent card ^54ay5s0 shows the resolve phase to the user in the agent CLI. A cancelled resolve that shows as a failure is wrong: the user made the cancel. This card depends on the cancellation card, because the `.cancelled` phase has no source until `runResolve` obeys the cancel.