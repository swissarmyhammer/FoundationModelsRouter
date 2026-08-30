---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1a7vvpffbpqgx08pxfyxg17
  text: |-
    ### The measurement is made. The TestSupport plan does not work.

    The card said to measure first whether the TestSupport target can reach the internal
    initializer, and to take the library fallback only if that failed. It failed.

    Method: a probe file in `Tests/FoundationModelsRouterTestSupport/`, built three ways,
    then removed.

    | probe | import | configuration | result |
    |---|---|---|---|
    | 1 | plain `import FoundationModelsRouter` | debug | `error: cannot find 'SessionMailbox' in scope` |
    | 2 | `@testable import FoundationModelsRouter` | debug | Build complete |
    | 3 | `@testable import FoundationModelsRouter` | release | `error: unable to resolve Swift module dependency to a compatible module: 'FoundationModelsRouter'` |

    Every file in TestSupport imports the library plain today, and the target touches no
    internal symbol. Thus it sees the public surface only, exactly as an outside package
    does.

    Probe 3 is what settles it. `@testable` needs the library built for testing, which
    `swift build -c release` does not do. So the release build of the TestSupport product
    fails. That is not a cost to the consumer alone: it breaks the release build of this
    package.

    So TestSupport cannot hold this seam. Do not try to put it there.

    ### Two facts that were wrong in the card

    1. The card said the consumer links the TestSupport product already. It does not. It
       links `FoundationModelsRouter` alone, in both of its manifests. The list of
       products I read was this package's own nested IntegrationTests manifest, not the
       consumer's. The mistake is mine.
    2. Thus "it costs the consumer no manifest change" was also wrong. It costs one.

    ### What the consumer added, which changes the balance

    The seam is needed by the consumer's UNIT test target, not only its integration
    target. That target links the library alone, holds 1316 tests and runs in about 24
    seconds.

    The other way to solve this is for the consumer to rewrite its fixtures to drive a
    real session. That would put real model sessions in that unit target. The consumer's
    standing constraint is that unit tests stay fast. So the rewrite is not only more
    work; it likely trades a 24-second suite for a slow one.

    ### What is left

    One question, and only one: there is no public way to obtain a `ToolContext`. The
    mailbox, the sink and the two delivery types all fall out of that. The consumer has
    already dropped the `SessionMailbox.` prefix from the two delivery types, which are
    public at the top level since ^hqxc1tp, so those two names are no longer part of it.

    The remaining shapes to weigh:

    - One `public static func detached(tool:op:)` on `ToolContext` in the LIBRARY. It
      makes its own mailbox and sink inside, so it exposes no internal type. Surface goes
      622 to 623. The documentation comment says it is a seam for a test, and that an
      application receives its context from the engine.
    - The consumer rewrites its fixtures, and this package publishes nothing. Cheapest
      here, and measurably expensive there.

    Do not build either one without a decision. The first is a standing promise in the
    shipping API.
  timestamp: 2026-08-30T21:05:34.415102+00:00
- actor: claude-code
  id: 01m1a95dn7y2h0d73ntm55c3m1
  text: |-
    ### Measured: build nothing. This card is closed unbuilt.

    An outside package can already do what this card wanted to publish a symbol for. It
    needs no new symbol, and no change of any kind to this package.

    Method: a probe file in the nested `IntegrationTests` package, which links this
    package through a product, exactly as an outside consumer does. Plain
    `import FoundationModelsRouter`, no `@testable`. Built, run, then deleted.

    Result:

    ```
    PROBE RESULT: sawContext=true completionToken=01M1A92CX5JDAA98S5RCTCCJH6
                  tool=probe op=probe answer=probed hi
    Test "A mounted tool sees a non-nil ToolContext.current, plain import, no model"
         passed after 0.029 seconds.
    ```

    A stub `ModelLoader`, a real `Router`, a real `RoutedSession`, a real mounted tool,
    and the tool reads a non-nil `ToolContext.current` inside its own `call(arguments:)`.
    No download, no inference.

    | step | wall clock |
    |---|---|
    | the test body | 0.029 s |
    | `swift test --skip-build --filter` | 2.18 s |
    | incremental build with the probe added | 7.9 s |

    118 lines, not blank and not comments, for the six protocol conformances. Every symbol
    the probe names is public today. No symbol was missing.

    ### Why the earlier answer was wrong

    Two claims made this card look necessary. Both were wrong, and both were wrong the
    same way: a person read the source text and did not run anything.

    1. "The consumer's fixtures cannot be rewritten without real model sessions, which
       would make a 24-second unit suite slow." Wrong. The stub loader is constructible
       from the public surface, and the measured cost of a probe of this shape is 29
       milliseconds.
    2. "There is no public way to answer an elicitation, so a rewrite is impossible."
       Wrong. `respond(elicitationId:response:)` and `complete(elicitationId:)` are
       requirements of the public protocol `RoutedSession`
       (Sources/FoundationModelsRouter/Session/RoutedSession.swift:44, :344, :350). A
       protocol requirement carries no `public` keyword on its own line, because it takes
       the access level of the protocol. A search for the keyword finds nothing there and
       never could. Both symbols are in the published symbol graph.

    ### Two facts a rewrite must know, from the probe

    1. The stub container MUST implement `makeSession(instructions:tools:)`. The public
       default of that method drops `tools` and forwards to `makeSession(instructions:)`.
       A container that writes only the two required factories gets a backend with an
       empty tool list, and then measures nothing. This is the one trap.
    2. `RoutedModel.makeSession` is what binds the context. It wraps each tool through
       `ToolMounting.makeSessionMounted` before it gives the list to the container, and
       the wrapper binds `ToolContext.$current` around each call. The wrappers keep the
       tool's `Arguments` and `Output`, so a stub backend casts a wrapped tool and calls
       it. Commit 377c1ee is what lets an outside conformer inherit the public defaults;
       without it these conformances do not compile.

    ### Outcome

    The public surface stays at 622. The consumer rewrites its fixtures. This package
    publishes nothing, which is the correct result and the one the consumer argued for.
  timestamp: 2026-08-30T21:28:16.295626+00:00
position_column: done
position_ordinal: ffffa880
title: Vend a detached ToolContext from the TestSupport product
---
## What

`ToolContext` has no public initializer. Both of its initializers are internal
(Sources/FoundationModelsRouter/Hosting/ToolContext.swift:65 and :104). So a package
outside this one can receive a context from the engine, and can mount through it with
`ToolContext.mount(_:op:as:)`, but cannot make one.

That blocks about 29 test files of FoundationModelsMultitool. Their fixtures make a
context to exercise the run plane:

```swift
func makeOuterRunContext(mailbox: SessionMailbox, sink: any OperationEventSink) -> ToolContext {
    ToolContext(
        sessionID: ULID(),
        mailbox: mailbox,
        sink: sink,
        tool: "runCode",
        op: "runCode",
        completionToken: SessionMailbox.makeCompletionToken(),
        isCancelled: { false }
    )
}
```

A second shape mounts with no context at all, through the `makeWrapped` overload that
takes a `sessionID` and a `mailbox`. `ToolContext.mount` cannot serve that shape,
because there is no context to mount on.

## Do NOT put this in the library

The four cards before this one each added one symbol to the library, because each
answered a question a shipping application asks. This question is different. Only a
test asks it. A detached context is not a thing an application needs, and a public
initializer on `ToolContext` would say this package supports an outside caller making
a context, which is a larger promise than the package wants to make.

`FoundationModelsRouterTestSupport` is a product of this package already
(Package.swift:93, target at Tests/FoundationModelsRouterTestSupport). The nested
`IntegrationTests` package links it already, and so does the consumer. That product is
where a test-only seam belongs.

So the library's public surface does not change. It stays at 622 symbols.

## What to do

Add to the TestSupport target:

```swift
extension ToolContext {
    /// A context over a mailbox of its own, for a test in another package to
    /// exercise a mounted tool.
    public static func detached(tool: String, op: String) -> ToolContext
}
```

It makes its own `SessionMailbox` and its own sink inside. The caller names neither.

This needs the internal initializer, thus the TestSupport target must reach it. Find
how the target reaches internals today, and follow that. If it uses
`@testable import`, that works for a test target but NOT for a product another
package links. Measure this first, because the answer decides the shape of the whole
card:

- If the seam can stay in TestSupport, that is the answer.
- If it cannot, the fallback is one `public init` on `ToolContext` in the library,
  marked in its documentation comment as a seam for tests. Do not choose the fallback
  without a measurement that shows the first way fails.

## The elicitation question, still open

The consumer's fixtures also read `SessionMailbox.ElicitationAnswerDelivery` and
`SessionMailbox.ElicitationCompletionDelivery`, and one drives elicitation answers
through the mailbox. Card ^hqxc1tp hoisted both delivery types to the top level and
made them public, so the two type names are reachable now. What is not settled is
whether a detached context can drive an answer, since `ToolContext.elicit` waits for
an answer that something must deliver.

Answer that question with a measurement, and write the answer on this card. Do not
publish a second seam before the first one is proved insufficient.

## Acceptance Criteria
- [ ] A package outside this one can make a context for a test, and mount a tool on
      it, while naming no internal type.
- [ ] The library's public surface does not change. Measure it: 622 before, 622
      after.
- [ ] The seam says in its documentation comment that it is for tests, and that an
      application receives its context from the engine.
- [ ] A test proves a tool mounted on a detached context runs, and that its events
      reach the context.
- [ ] The elicitation question above is answered on the card, with the measurement.

## Tests
- [ ] Add a test in the nested IntegrationTests package, which links the TestSupport
      product the way an outside consumer does, and not with `@testable`.
- [ ] Run `swift test`. All tests pass.
- [ ] Run `swift build --package-path IntegrationTests --build-tests`. It builds.

## Note

The consumer session raised this and said plainly that it is not asking for it now,
that it is not asking for a revert, and that its own user may rewrite the fixtures to
drive a real session instead. Confirm the direction before building this. A rewrite
on their side may be the better answer, and it costs this package nothing. #router #api #test-support