---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
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