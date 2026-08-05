---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7pz681y3nswrp7ktra74xs
  text: 'Research done. Plan: new gated suite Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift following the target''s established pattern (per-file FM_ROUTER_INTEGRATION_TESTS constant + .enabled(if:), GatedSuiteSerialGate.shared.withPermit in each body, RealModels.standard via LiveModelLoader + #hubDownloader/#huggingFaceTokenizerLoader). Probe tool `context_probe` (FoundationModels.Tool, @Generable single-string args, mirrors RecordingHandleIntegrationTests.EchoTool) records ToolContext.current != nil and the observed completionToken into an actor log from inside call(arguments:). Two @Test funcs: (1) MLX path — LanguageModelSession(model: container.model, tools:, instructions:) with the tool-forcing instructions/prompt shape RecordingHandleIntegrationTests already proved drives a tool call; (2) system path — SystemLanguageModel.default (Issue.record hard-fail if unavailable, never skip-as-pass). Each binds a real ToolContext (SessionMailbox + no-op OperationEventSink, minted completionToken) via ToolContext.$current.withValue around session.respond, then #require the probe actually fired and asserts binding identity via completionToken match. Verdict printed + recorded in doc comment and ../FoundationModelsMultitool/eventplan.md afterwards; branch decision executed per the card.'
  timestamp: 2026-08-05T01:00:25.217700+00:00
- actor: claude-code
  id: 01kz7qvknen4nm7thtpanztvzn
  text: |-
    Gated probe EXECUTED on real hardware (Apple Silicon, macOS 27.0 build 26A5388g, MacOSX27.0.sdk, Swift 6.4, 2026-08-04). VERDICT: the ToolContext task local PROPAGATES through Apple's respond() into call(arguments:) on BOTH paths. Verbatim run output (final run, after the pinned assertions were added):

    [PropagationProbe] MLX path verdict: ToolContext.current != nil inside call(arguments:) == true (observedCompletionToken=01KZ7QBPTPQ0D9XGSJ8136CJS7, bound=01KZ7QBPTPQ0D9XGSJ8136CJS7)
    [PropagationProbe] system-model path verdict: ToolContext.current != nil inside call(arguments:) == true (observedCompletionToken=01KZ7QC0M8YK1Y1FJ93WBFFFZB, bound=01KZ7QC0M8YK1Y1FJ93WBFFFZB)
    Test run with 2 tests in 1 suite passed after 14.110 seconds.

    (An earlier identical-verdict run also passed: MLX observedCompletionToken=01KZ7Q5BWC8KWB6Q9E17Q52371 == bound; system observedCompletionToken=01KZ7Q5W4AT8DV14RNXVTZ1W30 == bound.)

    Ungated `swift test`: 718 tests in 69 suites passed (main target) + 20 + 12 in the other targets, zero failures; the gated propagation probe suite is skipped ungated as designed.

    Branch decision executed (propagates): follow-up deletion task ^ew49xjj created on this board (delete EventEmittingTool/connecting(_:) + conformance-cast wiring). eventplan.md updated in the FoundationModelsMultitool working tree only (NOT committed): §Phases two-branch text replaced with the observed result, §The ambient context effect 3 now states the protocol is removed, and the two passages that still prescribed the protocol (§vocabulary move list; §MultiTool is a host and an emitter) were reconciled.

    ENVIRONMENT NOTE for future gated runs (this machine): `swift test` under the swiftbuild build system fails at MLX init with "Failed to load the default metallib" — the mlx-swift metallib search never finds the SPM resource bundle from the xctest layout. Workaround that works: (1) `swift build --build-tests`; (2) copy `.build/out/Products/Debug/FoundationModelsRouterIntegrationTests.xctest/Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib` to `.../FoundationModelsRouterIntegrationTests.xctest/Contents/MacOS/mlx.metallib` (the colocated-library path mlx checks first); (3) run `FM_ROUTER_INTEGRATION_TESTS=1 swift test --skip-build --filter ...`. IMPORTANT: remove the copied mlx.metallib before any subsequent build — codesign fails on the stray unsigned file inside Contents/MacOS. The copy was removed after the runs; the build tree is clean.
  timestamp: 2026-08-05T01:15:56.462939+00:00
- actor: claude-code
  id: 01kz7qwbkzv7cf4swxtvcmpwyn
  text: |-
    ### implement — changed
    - evidence: 1 new file — Tests/FoundationModelsRouterIntegrationTests/PropagationProbeIntegrationTests.swift (gated probe suite, verdict pinned); 1 working-tree-only edit outside this repo — ../FoundationModelsMultitool/eventplan.md (observed result recorded in §Phases + §The ambient context effect 3; contradicting passages in §vocabulary move list and §MultiTool is a host and an emitter reconciled; NOT committed); follow-up deletion task ^ew49xjj created. Gated run: FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter PropagationProbe → 2 tests in 1 suite passed; verdict: ToolContext PROPAGATES on both MLX and system-model paths (observedCompletionToken == bound token on each). Ungated swift test → 718 + 20 + 12 tests passed, zero failures.
    - next: /review
  timestamp: 2026-08-05T01:16:20.991721+00:00
depends_on:
- 01KZ6N3B3YC884JDVKEK4NYGQA
position_column: doing
position_ordinal: '80'
title: '[Router] Propagation probe (gated): does the task local survive respond()?'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"Phases" phase 1 (propagation probe) and §"The ambient context" effect 3.

## What
A gated test answering one question: when Apple's `LanguageModelSession.respond` calls a tool, does the `@TaskLocal ToolContext` bound around `respond()` arrive inside `call(arguments:)`, or is it `nil`?

- Add a probe tool that records `ToolContext.current != nil` (and the observed `completionToken`) from inside `call(arguments:)`.
- New gated suite in `Tests/FoundationModelsRouterIntegrationTests/` (gate: `FM_ROUTER_INTEGRATION_TESTS`, per-file constant + `.enabled(if:)` like the existing suites; acquire `GatedSuiteSerialGate.shared` in the test body). Bind the context around `respond()`, run one prompt that forces the probe tool call on the MLX path and one on the system model (follow `LanguageModelSessionBackendTests` fixtures / `RealModels.swift`).
- Record the answer in ../FoundationModelsMultitool/eventplan.md (replace the two-branch text with the observed result) and in the probe test's doc comment. Both outcomes are acceptable; the probe gates a file deletion, never the phase:
  - Propagates → native tools get ambient context free; create a follow-up kanban task to delete `EventEmittingTool`/`connecting(_:)` and the conformance-cast wiring this phase.
  - Does not propagate → the protocol stays as the native-path fallback, and the composition-time wiring must carry the full context (sink AND mailbox — elevation on the native path reads the mailbox from the ambient context). If this branch lands, verify `ElevatingTool`'s own per-call binding covers the mailbox need (it should, since the wrapper binds around the inner call) and record that in the test doc.
- Code mode is unaffected either way — `ToolInvoker` binds the context itself with no Apple code in the path.

Run it per the gated-run discipline: one `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter PropagationProbe` invocation at a time, nothing chained.

## Acceptance Criteria
- [x] Gated probe test exists, builds ungated, runs on both model paths when gated, and asserts a definite boolean per path (no skip-as-pass when the gate is on)
- [x] The observed result is recorded in ../FoundationModelsMultitool/eventplan.md and the branch decision is executed: either the deletion follow-up task exists on this board, or the keep-decision (with full-context wiring note) is documented
- [x] Ungated `swift test` in Router remains green (probe builds but does not fire)

## Tests
- [x] The probe IS the test: `FM_ROUTER_INTEGRATION_TESTS=1 swift test --filter PropagationProbe` passes with a recorded verdict on MLX and system-model paths
- [x] `swift test` (ungated) green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #phase-1 #router-first