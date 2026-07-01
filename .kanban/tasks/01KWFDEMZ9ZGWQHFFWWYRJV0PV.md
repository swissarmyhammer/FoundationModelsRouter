---
comments:
- actor: wballard
  id: 01kwfee66fmjjyzry59f4a5yb1
  text: |-
    Worked the 2026-07-01 review-findings checklist. Summary:
    - Acronym casing: renamed invalidJsonSchema→invalidJSONSchema (case + throw) and validateJsonSchema→validateJSONSchema (func + call site) in GuidedGeneration.swift. No test refs needed changing.
    - State modeling: replaced Router's residentToken+resolutionInFlight with residencyState: ResidencyState (nested enum idle/resolving/resident(ULID)). Exact semantics preserved (idle-guard, in-flight reject, defer resets only if still .resolving, release matches resident token).
    - Redundant inits: removed only InertKVCache's init() (internal final class, synthesized internal init matches). Kept all 10 public-struct public inits as load-bearing per the driver note.
    - New tests: HostProfile Codable round-trip, HostProfileCache overwrite save/load round-trip, RepoMetadata Codable round-trip, and two redact case-sensitivity tests documenting the caller-supplied-hook contract.
    - `swift test`: 124 tests / 19 suites PASS (gated integration suite skipped as designed). No compiler warnings from our code.
    Leaving task in `doing` for review.
  timestamp: 2026-07-01T18:18:09.487481+00:00
position_column: doing
position_ordinal: '80'
title: Review of whole codebase (swift validator)
---
Scope: `**/*.swift` (whole codebase), validators: [`swift`]. Range-mode review, 2026-07-01. Engine returned 61 findings; ~43 test-refactoring findings were dropped under the review skill's blanket exception (deduplicating/restructuring/renaming EXISTING test code is out of scope). The surviving source + new-coverage findings are below.

## Review Findings (2026-07-01 12:15)

### Source — acronym casing (restore Swift-idiomatic uppercase; aligns with the standing keep-`RAM`/`JSON`/`LLM` decision — these are residue from the earlier `naming`-validator churn, now waived)
- [x] `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:23` — Rename enum case `invalidJsonSchema` → `invalidJSONSchema` (JSON kept uppercase). Also update the throw at line 88. RESOLVED: renamed the case and the throw; matches the upstream MLX `GrammarError.invalidJSONSchema` casing. No test refs needed updating (guided tests match on `GuidedRequestError.self`/`.unsupportedSchemaConstructs`, not this case).
- [x] `Sources/FoundationModelsRouter/Guided/GuidedGeneration.swift:66` — Rename `validateJsonSchema` → `validateJSONSchema`. RESOLVED: renamed the private static func and its call site.

### Source — state modeling
- [x] `Sources/FoundationModelsRouter/Router.swift:44` — Router models mutually-exclusive state (`residentToken` + `resolutionInFlight`) with separate Bool + Optional, letting impossible states be representable. Replace both with `private var residencyState: ResidencyState = .idle` where `enum ResidencyState { case idle, resolving, resident(ULID) }`, making impossible states unrepresentable. RESOLVED: replaced both fields with `residencyState: ResidencyState` (nested private enum `idle`/`resolving`/`resident(ULID)`). Exact semantics preserved — resolve guards on `case .idle` (rejects while resident OR in-flight), enters `.resolving` before first suspension, a `defer` returns to `.idle` only if still `.resolving` (so success's `.resident(token)` is untouched but a throw before/after resets), success sets `.resident(residencyToken)`, and release matches `case .resident(let current), current == token` (the ULID is the residency token — a stale deinit still cannot clobber a newer profile). ProfileLifecycleTests + ResolveTests green (release-clears, second-resolve-rejected, stale-token-no-clobber).

### Source — redundant explicit initializers
DRIVER NOTE: for a PUBLIC struct, Swift synthesizes an INTERNAL memberwise/default init, so an explicit `public init` is NOT redundant — removing it silently narrows the public API to internal (still compiles + passes tests via `@testable import`, but breaks external consumers). Remove ONLY where the type + init access genuinely match the synthesized one (internal type, or internal init); otherwise resolve as "no change — public init is load-bearing" (a documented contradiction), do not blindly delete.
- [x] `Sources/FoundationModelsRouter/Recording/RouterManifest.swift:29` — NO CHANGE — `RouterManifest.Config` is a PUBLIC struct; its `public init` is load-bearing (synthesized memberwise init would be internal). Kept.
- [x] `Sources/FoundationModelsRouter/Recording/RouterManifest.swift:78` — NO CHANGE — `RouterManifest` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Resolution/ModelLoader.swift:20` — NO CHANGE — `DownloadProgress` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:52` — NO CHANGE — `CandidateReport` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:77` — NO CHANGE — `SlotResolution` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Resolution/SlotResolution.swift:122` — NO CHANGE — `ResolutionFailure` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Session/SessionKVCache.swift:17` — REMOVED — `InertKVCache` is an INTERNAL `final class` with no stored properties, so Swift synthesizes an internal `init()` that matches the declared access exactly; the explicit `init() {}` (and its doc) was genuinely redundant. Deleted; construction is internal-only (`makeCache()`/`copy()`), tests green.
- [x] `Sources/FoundationModelsRouter/Sizing/HostProfile.swift:44` — NO CHANGE — the public inits here (`HostProfile`'s memberwise + `SystemMachineProbe`'s `public init() {}`) sit on PUBLIC structs; a synthesized init would be internal, so they are load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift:8` — NO CHANGE — `HostProfileCache` is a PUBLIC struct; its `public init(cacheDir:)` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:6` — NO CHANGE — `RawRepoMetadata` is a PUBLIC struct; its `public init` is load-bearing. Kept.
- [x] `Sources/FoundationModelsRouter/Tools.swift:44` — NO CHANGE — `SummarizeTool` is a PUBLIC struct; its `public init` is load-bearing. Kept.

### New test coverage (additive — NOT refactoring existing tests)
- [x] `Sources/FoundationModelsRouter/Sizing/HostProfile.swift:27` — Add a `HostProfile` Codable round-trip test (encode → decode → assert equal), mirroring the `jsonValueRoundTrip` pattern. RESOLVED: added `HostProfileTests.codableRoundTrip` (new @Test, encode → decode → `#expect(decoded == profile)`).
- [x] `Sources/FoundationModelsRouter/Sizing/HostProfileCache.swift:49` — Add a `HostProfileCache` save/load round-trip test (save → load with same key → assert equal). RESOLVED: added `HostProfileTests.cacheOverwriteRoundTrip` (new @Test: save original, re-save updated for same key, load returns latest — a save→load round-trip covering the documented overwrite behavior, distinct from the pre-existing `cacheRoundTrip`).
- [x] `Sources/FoundationModelsRouter/Sizing/RepoMetadata.swift:41` — Add a `RepoMetadata` Codable round-trip test. RESOLVED: added `RepoMetadataTests.codableRoundTrip` (new @Test, encode → decode → assert equal on all architecture fields).
- [x] `Tests/FoundationModelsRouterTests/MergedAndRedactionTests.swift:221` — The `redact` hook does case-sensitive replacement of "secret". Add a test passing a non-canonical spelling ("Secret"/"SECRET") that documents intentional case-sensitivity — or make the hook case-insensitive if that's the intended contract. RESOLVED: source wiring left as-is (correct — the redact hook is caller-supplied, so match semantics are the caller's concern). Added two new @Tests documenting the contract: `redactHookIsAppliedVerbatim` (a lowercase-"secret" hook leaves "Secret"/"SECRET" untouched, only the exact-case token is replaced) and `callerSuppliesCaseInsensitiveRedaction` (a caller wanting case-insensitivity supplies a `.caseInsensitive` hook, and the router applies it verbatim).

## Dropped (blanket test-refactor exception — recorded here for transparency, NOT actionable)
~43 findings: extract duplicated test stubs (`StubProbe` ×8, `StubMetadataSource` ×6, `StubEmbeddingContainer` ×5, `CannedLLMContainer` ×2), `makeTempDir` ×8, `samplePartial` unify, to shared test utilities; test-identifier renames (`recordLlmLoad`, `configJson`, `treeJson`, `summarizeToolCallRecordsATurn`); unused `births` field; repeated test literal `profileDescription`. All modify pre-existing test code → out of scope per the skill. #review