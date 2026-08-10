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
- actor: claude-code
  id: 01kzpns3d4sv62bx81ds9dt7d2
  text: |-
    ### review — findings
    - scope: `review sha HEAD~1..HEAD` (commit `e6b6070`), 25 Swift files + this card's own 2 kanban files.
    - engine: 9 findings confirmed, 1 refuted, 45 attempted, 0 failed.
    - recorded: 3 findings. See the `## Review Findings (2026-08-10 15:07)` section.
    - dropped: 6 findings, all of them requests to change test code that already existed (5 `@unchecked Sendable` invariant comments and 1 assignOnlyProperty in `AutoCompactionTests.swift` and `ToolOutputCappingTests.swift`). The review skill drops these by a written rule.

    #### Behaviour preservation — verified independently, not taken on faith

    I did NOT re-use the implementer's word map, because a proof that applies the same map it is testing can hide a change. Instead I normalized BOTH the `HEAD~1` copy and the `HEAD` copy of every changed file by collapsing every word in the `elevat*`/`detach*` family to one token `X`, then compared. The normalization touches identifier words in that family only. It cannot erase a number, a JSON key, an access level, or a default value, so any such change survives it and shows in the difference.

    Result: 23 differing line pairs across all 25 Swift files. Every one is English text.

    - 15 pairs change the article `an` to `a`.
    - 4 pairs add the gloss "that plan's name for detachment" to the external `eventplan.md` citation.
    - 4 pairs are line re-wraps caused by that added gloss.

    Zero code lines differ. `git diff -M` did not pair `ElevationTestHelpers.swift` with `DetachmentTestHelpers.swift`, so I compared that pair by hand as well: one `an` -> `a` line, nothing else.

    #### Point checks

    - `DetachingTool.swift:59` `public static let defaultWaitSeconds: TimeInterval = 5` — present, named.
    - `DetachingTool.swift:65` `public static let defaultTimeoutSeconds: TimeInterval = 120` — present, named.
    - Pending envelope: `private static let renderedPrefix = "{\"pending\":true,\"completionToken\":\""` is byte-identical, `HEAD~1:168` and `HEAD:169`. The one-line shift comes from the added doc gloss.
    - `DetachConfiguration.Mode` still holds exactly `detaching` and `runToCompletion`.
    - `DetachingToolError` still holds exactly `timedOut(tool:timeoutSeconds:)`.
    - 4 surviving `elevat` occurrences in tracked files, all of them the deliberate `eventplan.md § "Elevation"` citation: `DetachingTool.swift:72`, `DetachingTool.swift:246`, `SessionTreeRestoration.swift:353`, `RoutedLLM.swift:324`. No missed rename.
    - `python3 Scripts/check-doc-links.py` — 0 stale, 0 unresolved. DocC symbol links survive the rename.
    - Commit contents: the only kanban files in `e6b6070` are this card's own `01KZP287R4XRJTCBY45N59EB1K.jsonl` and `.md`. The other session's cards are not in it.

    #### Migration symbol table on this card — complete and correct

    The public type surface at `HEAD` is exactly 5 declarations: `DetachmentParameterProviding`, `DetachConfiguration`, `DetachingToolError`, `DetachingTool`, `ToolDetachment`. All 5, and every member listed under them, appear in the table in the earlier comment. The 3 test-only names appear too. The table is a sufficient migration guide for FoundationModelsMultitool.

    #### Note on the 3 recorded findings

    All 3 sit on lines that `e6b6070` did not touch. `git blame` puts `SessionMailbox.swift:201` and `:630` on `8e9566f` ("feat(router): add SessionMailbox actor for parked run tracking"). The `ToolOutputCapping.swift` doc-parameter defect is likewise older than this commit. They are reported because the files are in the reviewed set. `Scripts/check-doc-links.py` checks symbol links only, which is why it did not catch the doc-parameter key defect.

    - next: fix the 3 findings, then re-run `/review ^n59eb1k`. `FM_ROUTER_INTEGRATION_TESTS=1` is still NOT run and must run before this card closes.
  timestamp: 2026-08-10T20:28:13.604892+00:00
- actor: claude-code
  id: 01kzpnvfedyv7dv62m51mr7xe5
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 25 Swift files, 3 git mv; Detach/Detaching/Detachment vocabulary
    - test: green — swift build 0 warnings; swift test 783 tests / 75 suites, 0 failures; check-doc-links.py 0 stale / 0 unresolved
    - commit: e6b6070
    - review: findings — Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:201, Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:630, Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:57
    - behaviour preservation independently proved: token-normalizing the elevat*/detach* word family on both HEAD~1 and HEAD leaves 23 differing line pairs, all English prose, zero code lines
    - NOT run: FM_ROUTER_INTEGRATION_TESTS=1 (27B model, 8-11 min) — AC line cannot be satisfied in this environment
    - next: fix the 3 findings, re-review
  timestamp: 2026-08-10T20:29:31.469303+00:00
- actor: claude-code
  id: 01kzpp7bh1kj6m8x6av0wk07ag
  text: |-
    Findings pass — what the code showed.

    Finding 1 (`settling` assignOnlyProperty). The property is **genuinely dead**, not an invisible read. Checked every use of a settling handle in the package: `park(...)`'s own local parameter is what the background observer awaits (`let terminal = await settling.value`), so the observer never touches `ParkedRun.settling`. The three readers of a `ParkedRun` value read other fields only — `status()` reads `tool`/`op`/`kind`/`latestProgressDetail`, `cancel(completionToken:)` reads `canceler`, `sweep()` reads `canceler` plus `tool`/`op`/`latestProgressDetail`. `ParkedRun` is a plain private struct with no `Equatable`/`Hashable` conformance, so the project waiver for synthesized conformances (periphery cannot see those reads) does not apply. Deleted the stored property and its one initializer argument; the public `park(tool:op:kind:completionToken:settling:canceler:)` signature is unchanged, so no caller and no test moved.

    Finding 3 (doc-parameter keys). Wrote a checker that walks each doc block, parses the declaration that follows it, and compares every `- Parameter` key against the internal parameter names. Ran it over all 25 still-existing Swift files of the rename commit `e6b6070`. It found 6 wrong keys, all in `ToolOutputCapping.swift` and all external labels: `toTokenLimit` (3 sites), `of`, `keepingAtMostUTF8Bytes`, `cappedToTokenLimit`. Fixed all 6. A repeat run over the touched set is clean, and a run over the whole of `Sources`/`Tests` reports nothing. Prose that names the external label was left alone — the rule states the prose may use it and binds only the `- Parameter <name>:` key.

    `Scripts/check-doc-links.py` is blind to this class, as the card says: it scanned 1292 symbol links and reported 0 stale and 0 unresolved both before and after, because it checks symbol links only.
  timestamp: 2026-08-10T20:36:00.673983+00:00
- actor: claude-code
  id: 01kzpp7m4yzrhxr52ygt5z647x
  text: |-
    ### implement — changed
    - evidence: 2 files — Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift (deleted the dead `ParkedRun.settling` stored property and its one initializer argument; named the nanosecond conversion `nanosecondsPerSecond` and used it in `boundedNanoseconds(clamping:)`), Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift (6 `- Parameter` keys moved from external labels to internal names: `of`→`text`, `keepingAtMostUTF8Bytes`→`maxBytes`, `toTokenLimit`→`limit` ×3, `cappedToTokenLimit`→`tokenLimit`).
    - verification: `swift build` complete, 0 warnings from the package; `swift test` — 783 tests in 75 suites passed (plus 24 + 24 in the two evaluation bundles), 0 failures, 1 pre-existing known issue in BoundedWaitTests; `python3 Scripts/check-doc-links.py` — 1292 symbol links scanned, 0 stale, 0 unresolved.
    - not run: `FM_ROUTER_INTEGRATION_TESTS=1` and `MULTITOOL_INTEGRATION=1` (27B model, 8–11 min) — the card's integration-test acceptance criterion stays **not-run**, not passed.
    - behaviour: unchanged. No threshold, clock, JSON envelope key, or mailbox semantic moved; the pending envelope stays `{"pending":true,"completionToken":"…"}`.
    - next: /review
  timestamp: 2026-08-10T20:36:09.502428+00:00
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

## Review Findings (2026-08-10 15:07)

- [x] `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:201` — var.instance `settling` is assignOnlyProperty.
- [x] `Sources/FoundationModelsRouter/Hosting/SessionMailbox.swift:630` — Magic numbers should be replaced by named constants.
- [x] `Sources/FoundationModelsRouter/Session/ToolOutputCapping.swift:57` — Parameters documented as `of` and `keepingAtMostUTF8Bytes` but the actual internal parameter names are `text` and `maxBytes`. Doc-parameter keys must use internal names, not external labels. Change the doc to `- Parameter text:` and `- Parameter maxBytes:` to match the actual internal parameter names.