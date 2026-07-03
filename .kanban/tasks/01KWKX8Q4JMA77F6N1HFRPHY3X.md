---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kwmcbg0xeckfbnjgmf16zdmj
  text: |-
    Implemented: added `defaultRecorderWiresRealJSONLRecorder()` to Tests/FoundationModelsRouterTests/TranscriptNestingTests.swift (new "Default recorder wiring" MARK section, after `firstLineIsSessionMetaThenTurn`). Builds a Router directly with `recordingsDir:` set and no `recorder:` argument, resolves, drives a session `respond(to:)` turn, and asserts a real transcript.jsonl is written under recordingsDir with correctly decoded [.session, .prompt, .response] events and matching routerId/sessionId.

    Verification:
    - Confirmed the test would fail without the real wiring: temporarily neutered `Router.defaultRecorder` to always return `NoneRecorder()`, reran just this test, watched it fail (file not found), then reverted Router.swift back to its original state (git diff confirms Router.swift is untouched in the final diff).
    - Full `swift test`: 153/153 passed (plus 1 skipped gated integration test), zero failures/warnings.
    - Adversarial double-check agent: PASS, no findings — confirmed no duplicate coverage exists elsewhere, confirmed the assertion targets the real `.full`/no-redact unwrapped recorder path, ruled out other code paths producing the file, checked placement/style/flakiness.

    No production code changes were needed — this was a pure coverage-gap task. Task left in `doing` per the implement/really-done workflow, ready for /review.
  timestamp: 2026-07-03T16:17:56.253917+00:00
position_column: doing
position_ordinal: '80'
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