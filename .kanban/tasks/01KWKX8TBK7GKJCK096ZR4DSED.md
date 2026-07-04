---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwmtqxxygw7y927wpzphsceq
  text: |-
    Added two direct tests for `ModelRef.init(repo:revision:)` to Tests/FoundationModelsRouterTests/CoreTypesTests.swift:
    - `modelRefMemberwiseInitWithRevision`: constructs `ModelRef(repo: "org/repo", revision: "abc123")`, asserts `.repo`, `.revision`, `.stringValue`, and equality against the equivalent string-literal `ModelRef`.
    - `modelRefMemberwiseInitWithoutRevision`: constructs `ModelRef(repo: "org/repo")` (default nil revision), same assertions against the equivalent string-literal `ModelRef`.

    Only the test file changed; no production code touched (the initializer already existed and worked correctly — this closes a coverage gap).

    Verification: `swift test` (full suite) — 155/155 tests passed, exit 0, no failures/warnings. Adversarial double-check agent verdict: PASS, no findings — confirmed the tests call the labeled initializer directly (not routed through the string-literal path), assertions are meaningful (stringValue is a real computed property, equality check cross-validates the two construction paths), no scope creep.

    Task is green and ready for /review. Leaving in `doing` per the implement skill contract.
  timestamp: 2026-07-03T20:29:23.774815+00:00
position_column: done
position_ordinal: a080
title: Add test for ModelRef.init(repo:revision:)
---
Sources/FoundationModelsRouter/Core/ModelRef.swift:36-39

Coverage: 85.7% (24/28 lines)

```swift
public init(repo: String, revision: String? = nil) {
    self.repo = repo
    self.revision = revision
}
```

Every existing `ModelRef` in the test suite and examples is built via the string-literal path (`init(_ string:)` / `ExpressibleByStringLiteral`), so the explicit memberwise `init(repo:revision:)` is never called directly. It's a real, distinct public initializer (not compiler-synthesized), so it should have its own direct test.

Add a small test constructing `ModelRef(repo: "org/repo", revision: "abc123")` and `ModelRef(repo: "org/repo")` (default `revision: nil`), asserting the fields and `stringValue` round-trip (`"org/repo@abc123"` and `"org/repo"` respectively) match the equivalent string-literal construction.