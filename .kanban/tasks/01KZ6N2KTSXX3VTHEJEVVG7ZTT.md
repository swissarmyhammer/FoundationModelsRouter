---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kz7d7b18f6z46xjbnswn5av7
  text: |-
    Picked up; research done. Discoveries:
    - Precedents in place: ToolContext (task-local, stamping rule, sink funneling), SessionMailbox (park/wait/cancel/sweep, makeCompletionToken), OperationEvent/Outcome vocabulary — all in Hosting/. TokenCappingTool (Session/ToolOutputCapping.swift) is the forwarding precedent: generic over Arguments, wraps `any Tool<Arguments, String>`, Output String.
    - MCP reference: raceThroughGate + CancellationGate (Mutex-based resume-once gate, register/cancel-before-registration states) is the continuation race primitive; CallDeadline is a pure resetCount + isElicitationPending struct compared before/after each full-timeout sleep; ambient cancellation of a bounded wait folds into deadlineElapsed (detach), per SoftDeadlineRace doc.
    - Design decisions: per-run RunEventFunnel actor is the single posting funnel — phase machine (running → elevated → settled) closes the race between deadline-elapse and natural settlement (elevate() returns false if already settled → caller returns the inline result instead of parking); upstream posts are FIFO-chained inside the funnel so synthesized progress can never arrive after the terminal; funnel drops a second .completed for the run (exactly-one enforcement point). Terminal synthesis rule: post .completed iff no terminal passed yet AND (elevated || run posted any event || outcome != succeeded) — silent in-window success posts nothing (OperationEventKind contract), abnormal endings always journal.
    - Elicitation suspension: funnel records posted elicitationIds and reconciles against mailbox.pendingElicitationIds() at each timeout checkpoint; a resolution bumps resetCount (endElicitation semantics).
    - ElevationParameterProviding takes opaque GeneratedContent; typed Arguments reach it via a runtime `as? any ConvertibleToGeneratedContent` cast (`.generatedContent`).
    - Platform: macOS 27, Synchronization.Mutex already used (AsyncSemaphore). @Generable test args keep memberwise inits (ToolOutputCappingTests precedent). Plan: sleep-based short-interval fixtures with generous ratios, no fake clock injection.
  timestamp: 2026-08-04T22:10:06.504541+00:00
- actor: claude-code
  id: 01kz7ejt9erm0yk1mqbs1jd845
  text: |-
    Implementation landed, then /double-check returned REVISE with 6 findings; all 6 are resolved:

    1. Elicitation-suspends-timeout coverage — added ElicitOnceTool/ElicitThenStallTool fixtures and two tests: an unanswered elicitation held across 3 full timeout windows never times out (call resolves to the answer), and an answered elicitation restores a fresh window so a run that then stalls still times out with exactly one .completed(timedOut).
    2. No `any Tool` entry point — added public `ToolElevation.wrapping(_:sessionID:mailbox:sink:configuration:)` mirroring ToolOutputCapping.wrapping's existential open. Documented + tested: a String-output tool is discovered and elevates; a non-String-Output tool passes through unchanged (un-elevated, in-band). Discovery during this fix: the Sendable half CANNOT be a runtime check — Sendable is a marker protocol with no runtime representation ("cast always succeeds" compiler warning), AND a Tool conformance with non-Sendable Arguments does not compile at all (Tool.call is @concurrent), so the pass-through case is unrepresentable; the factory bridges the metatype through Any with a documented always-succeeding cast, and the planned non-Sendable pass-through test was replaced by a source note explaining the unrepresentability.
    3. Cooperative-flag coverage — added CancellationFlagPollingTool + CancellationWitness: a mailbox cancel's flag reaches the tool through ToolContext.isCancelled (tool returns normally, honest .succeeded terminal, witness marked), and timeout expiry also raises the flag (witness marked after the timedOut throw).
    4. Clamp duplication — hoisted the one clamping rule to `SessionMailbox.boundedNanoseconds(clamping:)` (was private boundedWaitNanoseconds), now shared by wait() and both ElevatingTool clocks.
    5. Acceptance-criterion interpretation, recorded per the finding: criterion 6 ("exactly one .completed in every path (inline, elevated, tool-throws, cancel, timeout)") is scoped by criterion 1 and the OperationEventKind contract — a silent, successful, in-window run posts nothing at all ("may post nothing"); every run that posts any event, elevates, or ends abnormally gets exactly one .completed. This is What §5's own scope ("per elevated run") and is what RunEventFunnel.settleRun enforces and the terminal-scoped synthesis matrix tests pin.
    6. TDD evidence: Tests/FoundationModelsRouterTests/ElevatingToolTests.swift was authored first and observed failing (RED = compile failure "cannot find type 'ElevatingTool' in scope" et al., shell command 411 this session) before any of Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift existed; GREEN followed (16 tests, then 22 after the review-driven additions). No commit exists because this step's instructions forbid committing — commit belongs to the pipeline's commit step.

    Final verification: swift build --build-tests clean, zero warnings; full suite 703 + 18 + 12 tests green; ElevatingTool suite green 3 consecutive re-runs (~2.2 s each).
  timestamp: 2026-08-04T22:33:51.150300+00:00
- actor: claude-code
  id: 01kz7ek0qrpxf2xg4qast3yhya
  text: |-
    ### implement — changed
    - evidence: 3 files — Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift (new: ElevationParameterProviding, ElevationConfiguration, ElevatingToolError, PendingRunEnvelope, ElevatingTool, ToolElevation, RunEventFunnel, RaceGate, CancellationRequestFlag), Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (private boundedWaitNanoseconds → shared internal boundedNanoseconds(clamping:)), Tests/FoundationModelsRouterTests/ElevatingToolTests.swift (new: 22 tests covering the card's full matrix). swift test: 703 + 18 + 12 green, zero warnings, zero failures; ElevatingTool suite green 3 consecutive runs.
    - next: /review (task left in doing per the implement skill)
  timestamp: 2026-08-04T22:33:57.752461+00:00
- actor: claude-code
  id: 01kz7f4dwc5kh41ban4zhk9jzr
  text: |-
    ### review — findings
    - evidence: 4 findings — Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:195, :196, :197, :198 (scope: review sha HEAD~1..HEAD, commit 6cffe80)
    - next: add documentation comments to the four public forwarded properties (`name`, `description`, `parameters`, `includesSchemaInInstructions`), then re-review
  timestamp: 2026-08-04T22:43:28.268554+00:00
- actor: claude-code
  id: 01kz7f7r9dcgxrdzazzg8acvje
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 3 files (Hosting/ElevatingTool.swift new engine, SessionMailbox shared clamp, ElevatingToolTests new 22 tests)
    - test: green — swift test, 733 passed, 0 failures, 29 expected gated skips; ElevatingTool suite 5x re-run stable
    - commit: 6cffe80
    - review: findings — Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:195,196,197,198 (missing doc comments on forwarded public properties)
  timestamp: 2026-08-04T22:45:17.229162+00:00
- actor: claude-code
  id: 01kz7fb79wngdb858ayazzy1b1
  text: |-
    ### implement — changed
    - evidence: 1 file — Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift: added `///` doc comments to the four public forwarded properties (`name`, `description`, `parameters`, `includesSchemaInInstructions`) using the exact text the findings prescribed. Swept the whole file: every other public declaration (ElevationParameterProviding + requirement, ElevationConfiguration + members, ElevatingToolError + case, PendingRunEnvelope + members, ElevatingTool init/call, ToolElevation.wrapping) already carried a doc comment — no other undocumented public declarations. Note: TokenCappingTool's forwarded properties are internal, so its style (undocumented) does not apply to public API; used the findings' prescribed text. swift build --build-tests clean; swift test: 703 + 18 + 12 passed, zero failures. All 4 review findings flipped to [x].
    - next: /review (task left in doing)
  timestamp: 2026-08-04T22:47:10.908578+00:00
- actor: claude-code
  id: 01kz7fq6b7p97be48dwhwzmmk7
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (a7934cb) — 0 new findings, 9 validators attempted; all 4 prior 2026-08-04 17:37 findings checked
    - next: task moved to done
  timestamp: 2026-08-04T22:53:43.143405+00:00
- actor: claude-code
  id: 01kz7fr724hwybcyfwhe0bpah6
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (doc comments on the 4 public forwarded properties in Hosting/ElevatingTool.swift; whole-file sweep found no other undocumented public decls)
    - test: green — swift test, 733 passed, 0 failures, 29 expected gated skips
    - commit: a7934cb
    - review: clean — 0 new findings on HEAD~1..HEAD, all 4 prior findings checked; task → done
  timestamp: 2026-08-04T22:54:16.644943+00:00
depends_on:
- 01KZ6MZPV6VDYYDBACD3G930C4
- 01KZ6N1146TF1T334TRB3ARJR3
position_column: done
position_ordinal: eb80
title: '[Router] ElevatingTool engine with the two-clocks model'
---
Repo: this repo (FoundationModelsRouter). Basis: ../FoundationModelsMultitool/eventplan.md §"Elevation: waitSeconds and the completion token", §"MultiTool is a host and an emitter" (synthesized events), §"Consolidation of the siblings" (two clocks; promotion of MCP's `CallWait` and Shelltool's `RunSupervisor` race — reference designs at ../FoundationModelsMCP/Sources/FoundationModelsMCP/{CallWait,CallDeadline,MCPServer}.swift and ../FoundationModelsShelltool/Sources/ShellTool/ShellRunner.swift).

## What
New `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift`: a wrapper over `any Tool` at the `FoundationModels.Tool` protocol level. Follow the forwarding precedent of `Session/ToolOutputCapping.swift`'s `TokenCappingTool` (forward `name`/`description`/`parameters`/`includesSchemaInInstructions`, decorate only `call(arguments:)`). The wrapper's `Output` is the rendered value — a typed wrapped `Output` never represents the pending case; the model reads text on the wire either way.

Behavior of `call(arguments:)` with elevation on:
1. Mint a `completionToken` (ULID; it IS the run's event `correlationID`), bind `ToolContext` around the inner call via `ToolContext.$current.withValue`.
2. Race the inner call against a `waitSeconds` timer (default 5 s; `0` detaches immediately). Use a continuation-based race, not a task group — a group cannot exit with a suspended child (both reference designs agree; MCP's `raceThroughGate` is the cleaner primitive).
3. Completes in the window → return the rendered output inline. Nothing resets `waitSeconds`.
4. Window elapses → park the still-running call in the session's `SessionMailbox` (kind: `swiftTask`, cooperative canceler) and return the pending envelope as rendered output: `{ "pending": true, "completionToken": "01…" }`. At elevation, post one synthesized `progress` event iff the run has posted no events of its own yet.
5. Terminal synthesis is terminal-scoped, enforced at a single posting funnel (precedent: `MCPServer.postOperationCompletedEvent`): at settlement, the engine posts `.completed` — rendered output in `detail`, `completionToken` as `correlationID`, correct `OperationOutcome` (`succeeded`/`failed`/`timedOut`/`cancelled`) — iff no terminal event for that `correlationID` already passed the funnel. A tool that posted only `progress` still gets its `.completed` synthesized; a tool that posted its own terminal event gets no duplicate. Exactly one `.completed` per elevated run, emitter or not. Terminal events always go upstream, even if a snippet already collected the result via `wait()` — the journal must stay complete.
6. Two clocks: `waitSeconds` limits the block of the call and nothing resets it; a per-call `timeout` limits the work itself and progress resets it (port MCP's `CallDeadline.resetForProgress` loop; timeout suspends while an elicitation is pending, per `isElicitationPending`).
7. Elevation off (the mode `ToolInvoker` will mount for inner `tools.*` calls): the call runs to completion bounded only by `timeout`; same engine owns correlation, events, and outcomes.

Per-call clock sourcing — the mechanism is defined HERE, in this task (the MultiTool envelope task consumes it): a public protocol in `Hosting/`, e.g. `ElevationParameterProviding { func elevationClocks(from arguments: GeneratedContent) -> (waitSeconds: TimeInterval?, timeout: TimeInterval?) }`. If the wrapped tool conforms, the engine extracts per-call clocks from the opaque `GeneratedContent` via this hook; otherwise the wrap-time configuration applies (Router's mount default: 5 s). `nil` fields fall back to configuration.

## Acceptance Criteria
- [ ] A fast fake tool returns its rendered output inline; a tool that completes in-window and posts no events of its own produces no events at all
- [ ] A slow fake tool elevates: pending envelope rendered with `pending: true` and a ULID `completionToken`; mailbox holds the run; one synthesized `progress` at elevation; on settle exactly one `.completed` with output in `detail` and matching `correlationID`
- [ ] A tool that posts only its own `progress` events still yields exactly one synthesized `.completed`; a tool that posts its own terminal event gets no duplicate
- [ ] `waitSeconds: 0` detaches immediately; a per-call `waitSeconds` supplied through `ElevationParameterProviding` overrides the wrap-time default; progress resets `timeout` but never extends `waitSeconds`; `timeout` expiry cancels the work and yields outcome `timedOut`
- [ ] Elevation-off mode never parks and never returns a pending envelope
- [ ] Exactly one `.completed` in every path (inline, elevated, tool-throws, cancel, timeout)
- [ ] `swift test` green

## Tests
- [ ] New `Tests/FoundationModelsRouterTests/ElevatingToolTests.swift` with fake-clock/short-interval fixtures: inline fast path; elevation slow path (envelope shape, mailbox entry, event sequence); zero-wait detach; `ElevationParameterProviding` override; two-clocks matrix (progress resets timeout, not wait); terminal-scoped synthesis matrix (no events / progress-only / own-terminal); exactly-one-completed including tool-throws, cancel, and timeout paths; elevation-off mode
- [ ] `swift test --filter ElevatingTool` green; full suite green

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.

## Review Findings (2026-08-04 17:37)

- [x] `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:195` — Public computed property `name` lacks documentation comment. Public API items must have documentation. Add a documentation comment above the property: `/// The wrapped tool's name.`.
- [x] `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:196` — Public computed property `description` lacks documentation comment. Public API items must have documentation. Add a documentation comment above the property: `/// The wrapped tool's description.`.
- [x] `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:197` — Public computed property `parameters` lacks documentation comment. Public API items must have documentation. Add a documentation comment above the property: `/// The wrapped tool's parameter schema.`.
- [x] `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift:198` — Public computed property `includesSchemaInInstructions` lacks documentation comment. Public API items must have documentation. Add a documentation comment above the property: `/// Whether the schema is included in the tool's instructions.`. #phase-1 #router-first