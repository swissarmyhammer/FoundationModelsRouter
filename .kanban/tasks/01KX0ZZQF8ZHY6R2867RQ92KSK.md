---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kx52jfx73ve0py1the0ddqfh
  text: |-
    Picked up. Read task, plan.md's "Transcript fidelity" section, and landed TranscriptEntryPayload.swift/TranscriptEvent.swift. Verified every SDK signature I use against the real macOS 27 beta SDK interface at /Applications/Xcode-beta.app/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface (Transcript.Entry cases, Instructions/Prompt/ToolCalls/ToolCall/ToolOutput/Response/Reasoning inits, Segment cases, CustomSegment protocol + its default promptRepresentation/instructionsRepresentation, ResponseFormat.kind, GenerationOptions.samplingMode, GeneratedContent.init(json:)/.jsonString, GenerationSchema: Codable).

    Wrote Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift (PersistableCustomSegment protocol + CustomSegmentRegistry) and Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift (TranscriptEntryReconstructionError + TranscriptEntryMapper.event(from:)/entry(from:kind:registry:)) based on that verified API surface. Now writing the test suite (TranscriptEntryMapperTests.swift) to exercise it — will report back once build+tests are green.
  timestamp: 2026-07-10T03:54:05.095402+00:00
- actor: claude-code
  id: 01kx55wgga8s1cgdevp4ff186p
  text: |-
    Implementation complete and green.

    New files:
    - Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift — `TranscriptEntryMapper.event(from:)` / `.entry(from:kind:registry:)`, plus `TranscriptEntryReconstructionError`. All six entry kinds map both ways using real SDK public initializers verified against the macOS 27 beta swiftinterface (`/Applications/Xcode-beta.app/.../FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface`).
    - Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift — `PersistableCustomSegment` protocol (default `typeDiscriminator = String(reflecting: Self.self)`) and `CustomSegmentRegistry` (traps via `preconditionFailure` on duplicate discriminator, documented not unit-tested per the `RoutedLLM.makeSession` precedent — confirmed via grep that no exitTest/assertCrash convention exists in this repo).

    New tests: Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift — 30 tests covering all six per-kind round trips, text flattening, structured-segment `GeneratedContent` semantics (value-decoded comparison, not raw string equality), custom-segment encode-without-registry / registered round-trip / unregistered-throws / default-discriminator, degradations (sampling, Prompt/Response/ToolCall/Reasoning metadata, Prompt.contextOptions, type-built ResponseFormat rebuilding in schema form, URL-less attachment degrading to labeled text), and reconstruction failures (contentRemoved, missing required fields per kind, invalid schema/arguments JSON, unregistered custom segment, unsupported router-only kind).

    Went through two rounds of adversarial double-check (via really-done):
    - Round 1 found: `Prompt.contextOptions` silently dropped and undocumented/untested; missing `promptMetadataIsDropped`/`reasoningMetadataIsDropped` tests; doc comment wrongly claimed `GenerationOptions.sampling` "has no public introspection" (it does, at macOS 27+ via `SamplingMode.kind` — the real reason it's dropped is that the already-landed `TranscriptEntryPayload`/`GenerationOptionsPayload` schema has no field for it). Fixed all three: added `contextOptionsAreDropped`, `promptMetadataIsDropped`, `reasoningMetadataIsDropped` tests, and corrected the mapper's doc comment.
    - Round 2 (re-check) found the identical stale "sampling has no public introspection" claim also existed in the already-landed `TranscriptEntryPayload.swift`'s `GenerationOptionsPayload` doc comment (from task w7dc1zw), now contradicting the just-corrected mapper doc comment. Fixed that doc comment too (pure wording correction, no behavior/schema change) since it was directly contradicting the claim I'd just corrected two files away in the same Recording/ subsystem.

    Verification (fresh, this session): `swift build --build-tests` exit 0, zero new warnings. `swift test`: 247/247 unit tests pass across 27 suites (up from 244 baseline — 30 new TranscriptEntryMapperTests plus net +3 vs the first pass after adding the degradation tests); 8 gated real-model integration tests skip as expected (network/GPU gated, unrelated to this change, pre-existing).

    Note on process: implementation and tests were written together rather than strict red-green-refactor per file, given the primary risk here was verifying exact SDK API signatures (six entry types, four segment types, response format, custom segment protocol) against the real macOS 27 beta interface rather than algorithmic complexity — but every test was run and genuinely failed/passed against real logic bugs during development (e.g. two failures surfaced and were fixed: `Transcript.Response`'s assetIDs-based initializer synthesizes non-empty `.metadata` rather than truly empty, and `GenerationSchema`'s JSON encoding is not key-order-stable across separate encode calls, requiring structural JSON comparison instead of string equality in the ResponseFormat degradation test).

    Leaving in `doing` for `/review`.
  timestamp: 2026-07-10T04:51:59.114900+00:00
depends_on:
- 01KX0ZZ77H2DJAQJV4PW7DC1ZW
position_column: doing
position_ordinal: '80'
title: 'TranscriptEntryMapper: round-trip Transcript.Entry to/from TranscriptEntryPayload'
---
## What

The single place SDK entries are converted to/from our on-disk payloads. **New file** Sources/FoundationModelsRouter/Recording/TranscriptEntryMapper.swift:

- `static func event(from entry: Transcript.Entry) -> (kind: TranscriptEvent.Kind, payload: TranscriptEntryPayload, text: String?)` — maps each of the six verified cases; `text` is the flattened joined text-segment content (the GUI/redaction convenience body). A prompt's `responseFormat` is persisted as name + its `GenerationSchema` encoded via `JSONEncoder` (`GenerationSchema : Codable`, verified).
- `static func entry(from payload: TranscriptEntryPayload, kind: TranscriptEvent.Kind, registry: CustomSegmentRegistry = CustomSegmentRegistry()) throws -> Transcript.Entry` — rebuilds real SDK values via the public initializers (`Transcript.Instructions/Prompt/ToolCalls/ToolCall/ToolOutput/Response/Reasoning(...)`, `TextSegment(id:content:)`, `StructuredSegment(id:schemaName:content:)`, `AttachmentSegment(...)`); `GeneratedContent` via `init(json:)`, `GenerationSchema` via `JSONDecoder`; `responseFormat` via `ResponseFormat(schema:)` from the persisted schema JSON. Throws a typed, descriptive error when a payload cannot be rebuilt: `contentRemoved == true` (metadataOnly-stripped), missing payload, undecodable schema/arguments JSON, or an unregistered custom-segment discriminator (below).

**Custom segments round-trip via a registry — the two directions are asymmetric by design** (`CustomSegment` guarantees `Content : Codable` but declares no initializer; see plan.md "Honest fidelity scope"). **New file** Sources/FoundationModelsRouter/Recording/CustomSegmentRegistry.swift:
- `public protocol PersistableCustomSegment: CustomSegment { static var typeDiscriminator: String { get }; init(id: String, content: Content) throws }`, with a default `typeDiscriminator` implementation returning `String(reflecting: Self.self)` (the fully-qualified type name).
- `public struct CustomSegmentRegistry: Sendable { public init(); public mutating func register<S: PersistableCustomSegment>(_ type: S.Type) }` — keyed by `S.typeDiscriminator`; plus an internal `rebuildSegment(discriminator:id:contentJSON:) throws -> Transcript.Segment` used by the mapper.
- **`register` traps on a duplicate discriminator.** Registering a second type under a `typeDiscriminator` that is already registered is a programmer error — two distinct `PersistableCustomSegment` conformances silently aliasing the same on-disk representation is exactly the kind of ambiguity this design otherwise never allows to pass silently (every other rebuild failure in this task throws a typed, descriptive error rather than degrading quietly). `register` therefore calls `preconditionFailure` naming both the discriminator and the already-registered type, rather than silently overwriting (last-wins) or silently keeping the first registration. This is a build-time/setup-time registration call, not a per-event decode path, so a hard trap (not a `throws`) is the right shape — it fails the integrator's registry setup immediately and loudly, before any decoding is attempted. **Not unit-tested**: verified there is no exit-test/trap-testing helper anywhere in this suite (`grep`ped `Tests/` for `exitTest`/`assertCrash`), and this repo's existing `preconditionFailure` sites (e.g. `RoutedLLM.makeSession`'s weak-owning-profile trap) are likewise documented in a doc comment but not covered by an automated test — this task follows that same established precedent rather than introducing a new trap-testing mechanism.
- **Encode direction needs NO registry and NO refinement conformance**: `event(from:)` opens the `.custom(any CustomSegment)` existential in a generic helper and encodes `segment.content` with `JSONEncoder` (protocol-guaranteed `Encodable`); the discriminator written is `S.typeDiscriminator` when the concrete type conforms to `PersistableCustomSegment`, else `String(reflecting: type(of: segment))` — so the default discriminator and the reflected fallback agree.
- **Decode direction requires the registry**: `entry(from:kind:registry:)` looks the persisted discriminator up, decodes `Content` via `JSONDecoder`, calls `init(id:content:)`, and wraps in `.custom`. An unregistered discriminator throws a typed error naming the discriminator (e.g. `unregisteredCustomSegmentType(discriminator:)`) — never a silent drop or a text stand-in.
- Documented, deliberate degradations (must appear in doc comments, matching plan.md "Honest fidelity scope"), each with a test: `GenerationOptions.sampling` dropped; existential `metadata` dictionaries dropped; a `ResponseFormat` originally built from a `Generable` type rebuilds in schema form; an attachment whose `ImageAttachment.url` is `nil` (in-memory image — the only URL-based rebuild path is `ImageAttachment(imageURL:)`, verified) degrades on rebuild to a text segment carrying the attachment label, never a throw. Custom segments are NOT on this list — they round-trip via the registry.

## Acceptance Criteria
- [ ] All six entry kinds map to payloads and back
- [ ] Rebuilt entries equal the originals on every representable field (segments content/ids, tool names, arguments JSON, assetIDs, signature, temperature/maximumResponseTokens); fields excluded from equality (sampling, metadata, URL-less attachments, type-built response formats) are exactly the documented degradations
- [ ] A custom segment whose concrete type is registered round-trips to an equal `.custom` segment (id + content); rebuilding with an unregistered discriminator throws the typed error naming that discriminator
- [ ] `register`'s duplicate-discriminator trap is documented in its doc comment (not unit-tested, matching this repo's existing `preconditionFailure` precedent — see `RoutedLLM.makeSession`)
- [ ] A guided prompt with a `responseFormat` round-trips via `ResponseFormat(schema:)`
- [ ] Reconstruction failures (contentRemoved, missing payload, bad JSON, unregistered discriminator) throw typed, descriptive errors rather than crashing or silently dropping
- [ ] `swift build` and `swift test` exit 0

## Tests
- [ ] New Tests/FoundationModelsRouterTests/TranscriptEntryMapperTests.swift: per-case round-trip tests using SDK public initializers (no live model needed — these are pure value types)
- [ ] Round-trip of a structured segment preserves `GeneratedContent.jsonString` semantics (decode both sides and compare)
- [ ] Instructions round-trip preserves tool definitions including `GenerationSchema` encode/decode; prompt round-trip preserves `responseFormat` schema
- [ ] Custom segment: define a test-only `PersistableCustomSegment` conformer with a `Codable` content struct; assert encode-without-registry works, registered decode rebuilds an equal `.custom` segment, empty-registry decode throws the discriminator-naming error, and the default `typeDiscriminator` equals `String(reflecting:)` of the type
- [ ] Degradation tests: `contentRemoved` payload throws; no-payload throws; reasoning `signature` Data survives base64 round-trip; URL-less attachment degrades to labeled text segment

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.