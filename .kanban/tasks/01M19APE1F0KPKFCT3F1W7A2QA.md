---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m19g81p8gydjag85tbfaye9d
  text: |-
    ### Closed as a duplicate of ^zgzyhsj

    This card and ^zgzyhsj ask for the same thing. ^zgzyhsj is done, in commit 799c308.
    This card was written by an agent during a different card's run, while the same
    request was already being answered. No work is lost, and none is repeated.

    The answer is the second of the two choices in "What to do": a smaller facade.

    ```swift
    extension ToolContext {
        public func mount<T: Tool>(
            _ tool: T,
            op: String? = nil,
            as configuration: ToolMount = .synchronous
        ) -> any Tool<T.Arguments, T.Output>
    }
    ```

    `ToolMounting.makeWrapped` stays internal. The facade calls it with `self`, so all
    seven behaviours in this card hold, and behaviour 1, the mount arbitration, is
    covered by a test.

    Each acceptance item of this card:

    - An outside package can mount a tool with a public API, and the API has a
      documentation comment that says so — yes, `ToolContext.mount(_:op:as:)`.
    - The API keeps the seven behaviours — yes. It is one call to
      `makeWrapped(tool:inheriting:...)`.
    - `swift build` and `swift test` stay clean — yes. 1122 tests in 121 suites plus
      83 tests in 10 suites, 0 failed.
    - The tracing card is not blocked — correct. ^fypc46z is done, in commit 0f3fc7b.

    Each test item of this card:

    - A mount through the public API that keeps `Arguments` and `Output` — covered in
      Tests/FoundationModelsRouterTests/ToolContextMountTests.swift. A probe that
      imports the package without `@testable` type-checks, so the caller needs no cast.
    - A declared `.background` mount that beats a `.runToCompletion` call site —
      covered in the same file.
    - `swift test` passes.

    Two notes this card gets right, and one it does not:

    - Right: the `OperationEventSink` typealias needs no change here. It stays
      internal. The consumer conforms to `FoundationModelsExtras.OperationEventSink`.
    - Right: the demotion was a breaking change that was not seen.
    - Not right: the card assumes the fix must expose the mounting machinery. It does
      not. The consumer already holds a `ToolContext`, so the mount belongs on that
      type, and the public surface grows by one symbol: 619 to 620.

    One thing the consumer no longer needs: its own `AmbientUpstreamSink`. The router
    supplies that sink, as a private `MountedRunUpstreamSink`.
  timestamp: 2026-08-30T14:12:47.944544+00:00
depends_on: []
position_column: done
position_ordinal: ffffa580
title: Publish a supported mount entry point again — the demotion of ToolMounting broke an outside consumer
---
## What

Commit `6f0b2a8` "refactor(api): demote the mistakenly public Hosting plumbing
to internal" made `ToolMounting` internal. The symbol has a consumer outside this
package, thus the demotion is a breaking change that was not seen.

`FoundationModelsMultitool` calls
`ToolMounting.makeWrapped(tool:inheriting:sink:op:configuration:)` at
`Sources/FoundationModelsMultitool/Invocation/RunBinding.swift:148`. That
package builds on `branch: "main"` of this package and does not commit its
`Package.resolved`. Thus its CI resolves this package again on each run, takes
`b26ee0f`, and fails to build. Its `main` is red now:

```
Sources/FoundationModelsMultitool/Invocation/RunBinding.swift:184:29:
  error: cannot find type 'OperationEventSink' in scope
Sources/FoundationModelsMultitool/Invocation/RunBinding.swift:148:27:
  error: cannot find 'ToolMounting' in scope
```

Run 33261362318, 2026-08-29T15:51Z. Two symbols, and no others.

## Why makeWrapped cannot be replaced from outside

`ToolMounting.makeWrapped` is a thin dispatcher when it is read from inside this
package. From outside it is the only public door into the full session-plane run
machinery, because everything it builds is internal at `760ae89` and at
`b26ee0f`: `ToolRun`, `RunEventFunnel`, `BackgroundToolRunner`,
`RunToCompletionRunner`, `ContextBindingTool` and
`SessionMailbox.makeCompletionToken()`.

One call gives an outside binder seven behaviours together:

1. Mount arbitration. `ToolMounting.swift:42` reads
   `(typed as? any BackgroundTool)?.mount ?? configuration`, thus the tool's own
   declaration wins over the site's configuration.
2. Decorator dispatch by output type. A `String` output becomes
   `BackgroundToolRunner` or `RunToCompletionRunner`. Any other output becomes
   `ContextBindingTool`.
3. A completion token, made into the session mailbox.
4. The `ToolContext` binding, applied with `ToolContext.$current.withValue`.
5. The event funnel, which sends each event to the sink and the mailbox.
6. The invocation journal records, which the `op` string stamps.
7. Cancellation, and the clock of the mount.

Behaviour 1 is what makes a `BackgroundTool` conformance in an outside package
do anything. It is how each `runCode` call of the consumer goes to the
background and gives back a completion token while the snippet continues. An
outside package cannot build these seven behaviours from public parts. It would
write this package's session plane again.

## What to do

Do one of these two:

- Make `ToolMounting.makeWrapped` public again, and write in its documentation
  comment that it is the supported entry point that mounts a tool for a session
  from an outside package.
- Publish a smaller facade that gives an outside binder the same seven
  behaviours, and tell the consumer its name.

The second symbol does not need work here. `OperationVocabulary.swift:23`
declares `typealias OperationEventSink = FoundationModelsExtras.OperationEventSink`
without `public`. The consumer already uses `FoundationModelsExtras` and will
conform to `FoundationModelsExtras.OperationEventSink` directly. Make that line
public only if you prefer it.

## Acceptance Criteria

- [ ] An outside package can mount a tool on a session with a public API of this
      package, and the API has a documentation comment that says so.
- [ ] The API keeps all seven behaviours listed above. Mount arbitration is the
      one to protect: a tool that declares `BackgroundTool.mount` gets its own
      declaration, and not the configuration of the call site.
- [ ] `swift build` and `swift test` of this package stay clean.
- [ ] The tracing task that instruments the three decorators is not blocked by
      this change.

## Tests

- [ ] Add a test that mounts a tool through the public API from a test target
      that stands for an outside consumer, and asserts the returned tool keeps
      the `Arguments` and `Output` types of the wrapped tool.
- [ ] Add a test that a tool which declares `BackgroundTool.mount` with
      `.background` gets a background runner, although the call site gives
      `.runToCompletion`.
- [ ] Run `swift test`. All tests pass.

## Who asked

The `FoundationModelsMultitool` session, on 2026-08-29 and 2026-08-30. Four
messages went to the router session before this card. The report and the
evidence are the same in all of them. Nothing in this repository was changed by
that session. #router #api
