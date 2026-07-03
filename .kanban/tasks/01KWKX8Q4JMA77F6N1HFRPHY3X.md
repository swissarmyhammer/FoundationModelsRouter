---
assignees:
- claude-code
position_column: todo
position_ordinal: '8580'
title: Add test for Router's default JSONLRecorder wiring
---
Sources/FoundationModelsRouter/Router.swift:743-749 (`defaultRecorder(recordingsDir:)`, uncovered line 746)

```swift
private static func defaultRecorder(recordingsDir: URL?) -> any TranscriptRecorder {
    if let recordingsDir {
        return JSONLRecorder(directory: recordingsDir)     // line 746 — uncovered
    }
    return NoneRecorder()                                   // covered
}
```

Every existing test constructs `Router(...)` with an explicit `recorder:` stub, or with `recordingsDir: nil` (hitting the `NoneRecorder()` branch). No test constructs a `Router` with a non-nil `recordingsDir` and *no* explicit `recorder:`, so the real default wiring to `JSONLRecorder(directory:)` is never exercised.

Add a test that constructs `Router(recordingsDir: <temp dir>, ...)` without passing `recorder:`, drives a resolve + a session turn (with a stub `ModelLoader`, so no real MLX/network is needed — only the recorder wiring is under test), and asserts a real JSONL transcript file is written under the temp directory (matching what `JSONLRecorder` is expected to produce elsewhere in the suite).