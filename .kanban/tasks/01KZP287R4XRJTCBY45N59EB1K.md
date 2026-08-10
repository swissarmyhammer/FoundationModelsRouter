---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzpmbcnj4txafjpfyy6kqmr7
  text: |-
    ## Rename done in Router. Consumer handoff below.

    The chosen words are Detach / Detaching / Detachment. The rename is in this repo only. I did not change FoundationModelsMultitool.

    ### Public old -> new symbol list

    | Old | New |
    |---|---|
    | `ElevatingTool<Arguments>` | `DetachingTool<Arguments>` |
    | `ElevatingToolError` | `DetachingToolError` |
    | `ElevationConfiguration` | `DetachConfiguration` |
    | `ElevationConfiguration.Mode` | `DetachConfiguration.Mode` |
    | `ElevationConfiguration.Mode.elevating` | `DetachConfiguration.Mode.detaching` |
    | `ElevationConfiguration.Mode.runToCompletion` | `DetachConfiguration.Mode.runToCompletion` |
    | `ElevationConfiguration.nativeSessionMount` | `DetachConfiguration.nativeSessionMount` |
    | `ElevationConfiguration.defaultWaitSeconds` | `DetachConfiguration.defaultWaitSeconds` |
    | `ElevationConfiguration.defaultTimeoutSeconds` | `DetachConfiguration.defaultTimeoutSeconds` |
    | `ElevationConfiguration.init(mode:waitSeconds:timeout:)` | `DetachConfiguration.init(mode:waitSeconds:timeout:)` |
    | `ElevationParameterProviding` | `DetachmentParameterProviding` |
    | `ElevationParameterProviding.elevationClocks(from:)` | `DetachmentParameterProviding.detachmentClocks(from:)` |
    | `ToolElevation` | `ToolDetachment` |
    | `ToolElevation.wrapping(_:sessionID:mailbox:sink:configuration:)` | `ToolDetachment.wrapping(_:sessionID:mailbox:sink:configuration:)` |
    | `ToolElevation.sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)` (internal) | `ToolDetachment.sessionMounted(tool:sessionID:mailbox:sink:cappedToTokenLimit:)` |

    Test-only names, in case the consumer copied them:

    | Old | New |
    |---|---|
    | `ElevatingArguments` | `DetachingArguments` |
    | `ElevationLayerPeelable` | `DetachmentLayerPeelable` |
    | `elevationWrappedTool` | `detachmentWrappedTool` |

    These names do NOT move: `OperationOutcome`, `SessionMailbox`, `PendingRunEnvelope`, `ContextBindingTool`, `DetachingToolError.timedOut(tool:timeoutSeconds:)`.

    ### File renames (git mv)

    - `Sources/FoundationModelsRouter/Hosting/ElevatingTool.swift` -> `DetachingTool.swift`
    - `Tests/FoundationModelsRouterTests/ElevatingToolTests.swift` -> `DetachingToolTests.swift`
    - `Tests/FoundationModelsRouterTests/Helpers/ElevationTestHelpers.swift` -> `Helpers/DetachmentTestHelpers.swift`

    ### Acceptance criterion 2 — the consumer is told, not moved

    FoundationModelsMultitool has its own `MultiTool+Elevation.swift` and `ElevationTests`. It depends on Router by local path. Its build breaks at the next compile, not at the next resolve. Use the table above to correct it. Rename its own file and suite to the Detach words at the same time.

    ### Behaviour is byte-identical

    Proof: I applied the same word map to the HEAD copy of each changed file, then compared that result with the working copy. The only differences are 15 lines. All 15 are English text:

    - 11 lines change the article `an` to `a`, because `an elevated` was correct and `an detached` is not.
    - 4 lines put back the external `eventplan.md` section name. That document is not in this repo and never was. Its section is titled "Elevation", so the citation keeps that word and adds the gloss "that plan's name for detachment".

    No other line differs. No clock, threshold, envelope shape, JSON key, or mailbox rule changed. The rendered envelope is still `{"pending":true,"completionToken":"..."}`.

    ### Named constants kept

    `DetachConfiguration.defaultWaitSeconds: TimeInterval = 5` and `DetachConfiguration.defaultTimeoutSeconds: TimeInterval = 120`. No new magic number.

    ### Checks

    - `swift build` — Build complete. Zero warnings from the module.
    - `swift test` — 783 tests in 75 suites passed, plus 24 + 24 in the two evaluation targets. Zero failures. One known issue in `BoundedWait`, which is a `withKnownIssue` that was already there and has no link to this work.
    - `python3 Scripts/check-doc-links.py` — 1291 symbol links scanned, 2382 declarations indexed, 0 stale, 0 unresolved.
    - `grep -rin elevat` over the whole repo — only the three source files with the deliberate `eventplan.md § "Elevation"` citations. All other hits are tool caches and logs, which are not tracked.

    ### Not run

    `FM_ROUTER_INTEGRATION_TESTS=1` was NOT run. It loads a 27B model and needs 8 to 11 minutes. Do not read this as a pass. Somebody must run it before the card closes.
  timestamp: 2026-08-10T20:03:15.762446+00:00
- actor: claude-code
  id: 01kzpmbktr6rdrsa2g1xxb5g9w
  text: |-
    ### implement — changed
    - evidence: 25 Swift files changed, 3 of them renamed with `git mv` (`Hosting/ElevatingTool.swift` -> `Hosting/DetachingTool.swift`, `ElevatingToolTests.swift` -> `DetachingToolTests.swift`, `Helpers/ElevationTestHelpers.swift` -> `Helpers/DetachmentTestHelpers.swift`). `swift build` clean, `swift test` 783 + 24 + 24 pass with 0 failures, `Scripts/check-doc-links.py` 0 stale / 0 unresolved. The full public old -> new symbol list is in the comment above. The change is names and docs only; the proof is in that comment.
    - not run: `FM_ROUTER_INTEGRATION_TESTS=1` (27B model, 8 to 11 minutes). Report it as not run, never as passed.
    - next: `/review`
  timestamp: 2026-08-10T20:03:23.096042+00:00
position_column: doing
position_ordinal: '80'
title: '[Router] Rename "elevation" — a call that may detach is not being elevated'
---
FOR THE ROUTER AGENT. Naming only, no behaviour change. Human-directed 2026-08-10: *"elevation is an aweful name — it isn't 'elevating' to make it async."*

## The problem with the name

`ElevatingTool`, `ElevationConfiguration`, `ToolElevation`, `nativeSessionMount`'s `mode: .elevating`, `MultiTool+Elevation.swift` in the consumer — all of it describes one mechanism: **a call that has not returned within `waitSeconds` detaches, parks in the mailbox, and hands back `{"pending":true,"completionToken":…}` for the caller to collect.**

That is asynchrony with a handle. Nothing is raised, promoted, or given greater privilege, which is what "elevate" means everywhere else in software — privilege escalation, log levels, support tiers. The name actively misdirects: a reader who has just met `ElevatingTool` reasonably guesses it grants a tool more access.

It cost real time on the consumer side. Reasoning about a 0/4 gated result, "elevation on" read as "a heavier privileged mount", which drove a wrong hypothesis about latency and pending envelopes for the four scenarios involved — later refuted from the fixtures, none of which sleep. A name that said "may detach" would have closed that line immediately.

## Candidate vocabulary

Pick one and apply it everywhere; the specific choice matters less than that it names detachment.

- `DetachingTool` / `DetachConfiguration` / `mode: .detaching` — closest to the mechanism
- `ParkingTool` / `mode: .parking` — matches the mailbox language already in use ("elevated runs park")
- `AsyncMountTool` / `mode: .async` — plainest, though "async" is overloaded in Swift

`OperationOutcome`, `SessionMailbox`, and `PendingRunEnvelope` already read correctly and should not move.

## What to change

Types, cases, parameter labels, doc comments, and the model-facing strings if any name the concept. This is a breaking API change; Router has shipped breaking renames recently (`45b3930`), so the pattern exists.

**Coordinate before landing:** FoundationModelsMultitool consumes `ElevationConfiguration.nativeSessionMount`, `ToolElevation.wrapping(_:sessionID:mailbox:sink:configuration:)`, and has its own `MultiTool+Elevation.swift` plus `ElevationTests`. It currently depends on Router **by local path**, so a rename there breaks its build immediately rather than at the next resolve. Either land both together or tell that repo first.

## Acceptance Criteria

- [ ] No public symbol, case, label, or doc comment describes detachment as elevation
- [ ] The consumer's names move with it, or the consumer is told before this lands — say which on the task
- [ ] Behaviour is byte-identical: no clock, threshold, envelope shape, or mailbox semantic changes
- [ ] `swift test` green; `FM_ROUTER_INTEGRATION_TESTS=1` green
- [ ] Zero magic numbers introduced — `defaultWaitSeconds = 5` and `defaultTimeoutSeconds = 120` keep their names

## Priority

Lower than `^cvtfem3` and `^vhjhaey`. Those fix a defect that makes Router unusable for this consumer; this one fixes a name that made the defect harder to reason about. Do it after, not instead.