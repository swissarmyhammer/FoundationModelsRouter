---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m19dyqr9mmx4bdngmjpwc4s6
  text: |-
    Research done. What I found:

    - `ToolMounting.makeWrapped(tool:inheriting:sink:op:configuration:tracer:)` returns `any Tool`, not a typed existential. So the new public function must do the conditional cast itself and degrade to the tool it was given, the same way `RunBinding.invoke` degrades today. This keeps the cast out of the caller.
    - `tracer` already defaults to `nil` on `makeWrapped`, and `RouterTracing.tracer(explicit:)` reads `InstrumentationSystem.tracer` at call time. So `tracer: nil` needs no `import Tracing` at the new call site.
    - `OperationEventSink` gives `post(invocation:)` a default, which is why `MountFixtures.RecordingSink` implements only `post(event:)`. The new sink forwards `post(event:)` alone, because `ToolContext` publishes no invocation egress. This matches `AmbientUpstreamSink` in FoundationModelsMultitool exactly.
    - Test fixtures already exist for every case: `MountFixtures.FastTool`, `.GatedTool`, `.DeclaredRunToCompletionRunner`, `.NonStringOutputTool`, and the top-level `AmbientNonStringOutputTool` (posts through the ambient context and returns its own run's completion token as its output). The last one proves the double re-stamp: inner context stamps, then the mounting context re-stamps, so the outbox sees the outer run.
    - Public surface baseline captured with `swift-symbolgraph-extract` at `-minimum-access-level public`: 619 symbols. The same extraction runs after the change to prove the count goes to 620 and the one new entry is `ToolContext.mount(_:op:as:)`.
  timestamp: 2026-08-30T13:32:45.705985+00:00
- actor: claude-code
  id: 01m19ec402p0etzeq25yyn6zmb
  text: |-
    Implementation landed, with TDD.

    RED: the six tests in `ToolContextMountTests.swift` were written first. `swift build --build-tests` gave `value of type 'ToolContext' has no member 'mount'` at each mount site, plus `cannot convert value of type '_.Arguments' to specified type 'MountArguments'` at the three type-annotated mounts. GREEN after `ToolContext.mount(_:op:as:)` landed.

    What the implementation holds, in `Hosting/ToolContext.swift`:
    - `public func mount<T: Tool>(_:op:as:)` in a new `// MARK: - Mounting capability` section of the type, next to the other capabilities. It calls `ToolMounting.makeWrapped(tool:inheriting:sink:op:configuration:tracer:)` with `tracer: nil`.
    - `private struct MountedRunUpstreamSink` at file scope, which forwards `post(event:)` to `context.post(_:)`. Private, so it adds nothing to the public surface.
    - The cast to `any Tool<T.Arguments, T.Output>` falls back to the tool itself, which matches the degradation `RunBinding.invoke` uses today.

    Proof of "no other symbol becomes public": `swift-symbolgraph-extract -minimum-access-level public` before and after. 619 symbols to 620, and the diff has exactly one added line, `ToolContext.mount(_:op:as:) | swift.method`. `ToolMounting`, `SessionMailbox`, `OperationEventSink` and `Tracer` are all absent from both lists.

    Proof the entry point serves an outside caller: a throwaway probe with a plain `import FoundationModelsRouter` (never `@testable`) type-checks `let engine = context.mount(tool, op: journalOp, as: mount); return try await engine.call(arguments: arguments)` at `T.Output`. That is the shape of FoundationModelsMultitool `RunBinding.invoke`, with no conditional cast left in the caller.

    Two things I changed after a first pass, to remove duplication I had introduced:
    - The declared-mount test first held a gate past the configuration's timeout, which made it a near copy of `ToolMountingTests.declaredMountOverridesTheSiteConfiguration`. It now mounts `DeclaredBackgroundToolRunner` with `as: .synchronous` and reads the two facts that only the declaration explains: a `BackgroundToolRunner` and a `nil` clock. Shorter, no sleep, and no copy.
    - Each test opened with the same three setup lines. A private `Host` struct and a `makeHost()` helper hold them one time.

    The whole new suite now runs in 0.001 seconds.
  timestamp: 2026-08-30T13:40:04.226022+00:00
- actor: claude-code
  id: 01m19ec9a16mg7y08n9n657gzs
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Hosting/ToolContext.swift (+75), Tests/FoundationModelsRouterTests/ToolContextMountTests.swift (new, 6 tests). `swift test`: 1122 tests in 121 suites and 83 tests in 10 suites, 0 failures, 2 pre-existing known issues (RealModelHarness, BoundedWait). `swift build --package-path IntegrationTests --build-tests`: Build complete. Public surface 619 to 620, one added symbol.
    - next: /review
  timestamp: 2026-08-30T13:40:09.665521+00:00
position_column: doing
position_ordinal: '80'
title: Add a public mount entry point to ToolContext
---
## What

An outside package cannot mount a tool on a session. `ToolMounting` and its two
`makeWrapped` functions are internal (Sources/FoundationModelsRouter/Hosting/ToolMounting.swift:5,
:9, :33). FoundationModelsMultitool used the public form of these functions, and its
`main` is now red:

    Sources/FoundationModelsMultitool/Invocation/RunBinding.swift:148:27:
      error: cannot find 'ToolMounting' in scope

Do not make `ToolMounting` public again. Add one public function instead. This is the
minimum surface, because it adds no new public type.

Add this function in an extension of `ToolContext`:

```swift
public func mount<T: Tool>(
    _ tool: T,
    op: String? = nil,
    as configuration: ToolMount = .synchronous
) -> any Tool<T.Arguments, T.Output>
```

The function calls `ToolMounting.makeWrapped(tool:inheriting:sink:op:configuration:tracer:)`
with `self` as the context.

Each type in this signature is public already:

- `ToolContext` — Sources/FoundationModelsRouter/Hosting/ToolContext.swift:10
- `ToolMount` — Sources/FoundationModelsRouter/Hosting/ToolMount.swift:5
- `Tool` — the FoundationModels framework

These stay internal. Do not make them public:

- `ToolMounting` and the two `makeWrapped` functions
- `SessionMailbox`, which the function reads from `self.mailbox`
- the `OperationEventSink` typealias — Sources/FoundationModelsRouter/Hosting/OperationVocabulary.swift:23
- `Tracer`, which is not in the signature

Because `SessionMailbox` stays out of the signature, task ^hqxc1tp can demote it later.

## The event route

The caller gives no sink. The function makes the sink, and the sink sends each event
through `self.post(_:)`.

This is correct for a tool that a tool call mounts. `ToolContext.post(_:)`
(ToolContext.swift:131) puts its own identity on each event it sends. So the events of
the inner run go to the session outbox with the correlation of the outer run, which is
the operation that the session started. The `completionToken` of the inner run stays
with the background runs.

FoundationModelsMultitool writes this sink itself today, as `AmbientUpstreamSink`
(RunBinding.swift:170). The router must supply it, so that no other package writes it
again.

## The return type

Return `any Tool<T.Arguments, T.Output>`, not `any Tool`. Each decorator keeps the
`Arguments` type and the `Output` type of the tool it wraps, and the fallback in
`makeWrapped` returns the tool itself, which also keeps them. A caller must not need a
conditional cast.

## The tracer

Give `tracer: nil` to `makeWrapped`. `RouterTracing.tracer(explicit:)`
(Sources/FoundationModelsRouter/Tracing/RouterTracing.swift:286) then reads
`InstrumentationSystem.tracer` at the time of the call. This is the resolve-late shape
that the package uses.

If a measurement shows that a mounted tool must use the tracer of its session, put the
tracer on `ToolContext` as an internal property. Do not put it in the signature.

## Acceptance Criteria
- [x] `ToolContext.mount(_:op:as:)` is public.
- [x] The package makes no other symbol public. Compare the public surface before the
      change and after it.
- [x] A tool that the function mounts writes its events to the outbox with the
      correlation of the context.
- [x] A tool with a `String` output and a `.background` mount goes to the background and
      gives back a completion token.
- [x] A tool that declares its own `BackgroundTool.mount` uses that mount, and not the
      `configuration` argument.
- [x] A tool with an output that is not a `String` gets the context binding.
- [x] The caller needs no cast. The return type carries `Arguments` and `Output`.

## Tests
- [x] Add `Tests/FoundationModelsRouterTests/ToolContextMountTests.swift`.
- [x] Test each of the three decorators through the new function.
- [x] Test that the tool's own declared mount wins over the `configuration` argument.
- [x] Test that the events of the mounted tool carry the correlation of the context.
- [x] Run `swift test`. All tests pass.
- [x] Run `swift build --package-path IntegrationTests --build-tests`. It builds. Do not
      use the command without `--build-tests`, because that command builds nothing.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #hosting