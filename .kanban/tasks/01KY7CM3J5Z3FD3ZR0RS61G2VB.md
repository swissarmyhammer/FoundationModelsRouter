---
comments:
- actor: claude-code
  id: 01ky7fpd7npvcf2d3t8vp18k66
  text: |-
    Package update done: FoundationModelsOperationTool bumped from dd40851c to a1dcdbc6 (feat: ForkableTool.forked + EventEmittingTool.connecting, replacing connect(_:)/OperationEventSinkHolder). `swift build` confirmed the new API surface and failed exactly where expected (RoutedSession.swift's `.connect(outbox)` call, now removed from EventEmittingTool).

    Implementation plan after reading Operations' new EventEmittingTool.swift/ForkableTool.swift/EventEmittingContext.swift/ForkableContext.swift and their tests:
    - RoutedSessionActor gets two tool fields: `originalTools` (private, the constructor-supplied tools, pre-instancing, retained only for fork lineage) and `tools` (internal, the per-session INSTANCED list — what's actually threaded to the backend).
    - Root construction (RoutedLLM.makeSession): outbox + instanced tools are now computed at the CALL SITE, before `container.makeSession(instructions:tools:)` is invoked, so the backend actually receives the sink-bound copies — this couldn't work inside RoutedSessionActor's init anymore since with pure (non-mutating) `connecting(_:)`, instancing after backend construction produces a value nobody references. This is a necessary structural change beyond just RoutedSession.swift: the old mutation-based design relied on retroactively mutating already-shared tool objects post-backend-construction; pure value semantics close that loophole (which was literally the bug being fixed).
    - `RoutedSessionActor.fork()`: builds `childOutbox`/`childTools` via fork-then-connect from `originalTools` (never from the parent's already-instanced `tools`), per the task's exact snippet.
    - `makeRoutedSessionActor`/actor `init` gained `originalTools:` and `outbox:` params, both defaulted, so 3 unrelated test call sites that construct `RoutedSessionActor` directly (SessionSidecarTests, LanguageModelSessionBackendTests, TranscriptReconstructionIntegrationTests) keep compiling unchanged.
    - `backend.makeFork()` (LanguageModelSessionBackend protocol / MLXFoundationModelsSessionBackend) is NOT touched — it's a separate, pre-existing mechanism for the live model's actual tool-calling capability, untested by the unit suite (stub backends ignore tools entirely), and out of this task's stated scope.

    `swift build` (library) is green with this shape. Now rewriting SessionOutboxToolWiringTests.swift per the Tests section, then running the full verification pass.
  timestamp: 2026-07-23T12:37:35.605070+00:00
- actor: claude-code
  id: 01ky7gfj7wbsdtzp7gsan9c0tc
  text: |-
    Implementation complete and verified green.

    Changes:
    - Sources/FoundationModelsRouter/Session/RoutedSession.swift: RoutedSessionActor now has `originalTools` (private, pristine, pre-instancing — retained only for fork lineage) and `tools` (no longer private, the per-session INSTANCED list). init's old `for tool in tools { connect(outbox) }` mutation loop is gone; init/makeRoutedSessionActor now accept already-built `tools:`/`originalTools:`/`outbox:` (all defaulted so the 3 unrelated direct-construction test call sites keep compiling unchanged). `fork(workingDirectory:)` builds `childOutbox`/`childTools` from `originalTools` (never from `self.tools`) via the exact fork-then-connect snippet from the task description. `originalTools` is threaded unchanged through every fork generation (deliberate: guarantees `forked()` is always invoked on a never-connected tool, avoiding a stale-sink-via-naive-forked()-blanket-copy failure mode for ForkableTool-only, non-`EventEmittingTool` conformers — traced this by hand for a fork-of-a-fork case, confirmed correct).
    - Sources/FoundationModelsRouter/RoutedLLM.swift: makeSession(grammar:instructions:workingDirectory:tools:) now computes the outbox + pure-instanced tool list BEFORE calling container.makeSession(instructions:,tools:) — a necessary structural change beyond RoutedSession.swift, since pure (non-mutating) connecting(_:) closes the loophole the old mutation-based design relied on (instancing after backend construction used to work only because mutating a shared object retroactively updated what the backend already held).
    - Sources/FoundationModelsRouter/Resolution/LiveModelLoader.swift: doc-comment-only fix — MLXFoundationModelsSessionBackend.makeFork()'s comment no longer claims to "mirror" RoutedSessionActor's reconnect (no longer true); clarified it's a separate, pre-existing, out-of-scope mechanism for live model tool-calling, untouched by this task.
    - Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift: fully rewritten, 9 tests (was 6) covering every acceptance criterion, including the concurrent parent-vs-fork independent-posting test and the ForkableTool fixture (forked-then-connected, generation-marked) test.

    Verification (fresh, this session): `swift build` clean; `swift build --build-tests` clean (only the known pre-existing mlx-swift_Cmlx.bundle warning); `swift test` green — 404 tests in 43 suites (baseline was 401; net +3 from the rewritten test file), gated integration suite's 15 tests in 5 suites all skip as expected (no GPU).

    Adversarial double-check (separate agent, independently re-ran the build/test suite and traced the protocol definitions against the vendored Operations checkout): PASS. It independently confirmed all 6 acceptance-criteria scenarios, confirmed no stale "reconnect"/mutation-era language remains anywhere in Sources/, and hand-traced the grandfork (fork-of-a-fork) case as correct by construction — flagged only as an observation (not a defect) that no test exercises grandfork tool/outbox independence specifically, beyond what the acceptance criteria required.

    Package update: FoundationModelsOperationTool bumped dd40851ce33414e42fc099b7078f5cb8264fff13 → a1dcdbc6e48395a7eb7b7a72bfd9590974c8d4e2 (feat: ForkableTool.forked + EventEmittingTool.connecting).

    Leaving task in doing for /review per the /implement process — not moving to review or using complete task myself.
  timestamp: 2026-07-23T12:51:19.932589+00:00
position_column: doing
position_ordinal: '80'
title: 'Adopt per-session tool capabilities: instanced tool lists, fork-then-connect at fork'
---
## What

Adopt OperationTool's pure per-session tool capabilities — `EventEmittingTool.connecting(_:)` and the new `ForkableTool.forked()` (both replacing the removed `connect(_:)` mutation and `OperationEventSinkHolder`; see that repo's board, `long-running` tag) — so event delivery never migrates between sessions and forkable tools get a real fork lifecycle.

Problem being fixed: the shipped wiring reconnects the *same* tool instances to a fork's fresh outbox, and one instance holds one sink — so after `fork()`, background events from operations the *parent* started post to the fork's outbox, and the parent goes deaf.

Rework in `Sources/FoundationModelsRouter/Session/RoutedSession.swift` (and wherever the auto-connect loop lives):
- Session construction: replace the `connect(outbox)` mutation loop with a pure map — `let instanced = tools.map { ($0 as? any EventEmittingTool)?.connecting(outbox) ?? $0 }` — and thread **`instanced`** (not the originals) into the backend / underlying `LanguageModelSession(tools:)`. Retain the *original* tools for fork lineage.
- `fork(workingDirectory:)`: build the child's tool list from the **originals** with fork-then-connect composition, exactly this shape:
  ```swift
  let childTools = tools.map { tool in
      let forked = (tool as? any ForkableTool)?.forked() ?? tool   // forkable → fork; else share the original
      return (forked as? any EventEmittingTool)?.connecting(childOutbox) ?? forked
  }
  ```
  Fork semantics are the tool's own business (the blanket default is a value-semantics copy); Router's job is purely this mechanical map. The parent's instanced tools (and any detached work that captured the parent's sink at operation start) keep posting to the parent — delivery never migrates. Update the fork-behavior doc comment that currently describes the reconnect-moves-delivery tradeoff; that tradeoff no longer exists.
- No other outbox/injection/prompt-queue behavior changes.

Update tests: the wiring tests (`SessionOutboxToolWiringTests`) assert instancing instead of mutation — in particular a fork test proving **both** parent and fork receive their own operations' events concurrently (the exact scenario the old design failed); a pre-fork capture keeps posting to the parent after the fork; a `ForkableTool` fixture is forked at fork time while a plain tool passes through shared.

## Acceptance Criteria
- [x] A fake emitting tool passed in `makeSession(tools:)` delivers events to that session's outbox with no explicit wiring call anywhere; non-conforming tools pass through untouched
- [x] The model-facing tool list is the instanced list (the underlying `LanguageModelSession` receives the sink-bound copies)
- [x] After `fork()`: an operation started via the parent's instance posts to the parent's outbox; one started via the fork's instance posts to the fork's outbox — both verified in one concurrent test
- [x] A sink captured at operation start before the fork continues posting to the parent after the fork
- [x] At fork, a `ForkableTool` fixture's `forked()` is invoked and its result (not the original) lands in the child's tool list; a plain tool is passed through shared
- [x] Fork doc comments updated: the delivery-migration tradeoff text is gone, replaced by the fork-then-connect model
- [x] Public API documented; `swift test` fully green in this repo

## Tests
- [x] Reworked `Tests/FoundationModelsRouterTests/SessionOutboxToolWiringTests.swift` (+ fork tests) covering the criteria above
- [x] `swift test` fully green in `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter`

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #long-running