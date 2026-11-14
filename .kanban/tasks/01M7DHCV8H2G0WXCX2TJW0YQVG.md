---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Recovery prompts name tool calls in sessions with no tools
---
## Problem

`RoutedSessionActor.reasoningStopContinuationPrompt` (`Session/RoutedSessionActorReasoningStop.swift`), `repetitionStopActRequest` and `finalPassPrompt` (`Session/RoutedSessionActorRepetitionWatch.swift`) tell the model "one tool call … or your final answer" / "make it now with one tool call". A session with no tools gets that text too, and the model is told to call a tool it does not have.

Found while working ^qmewzw0, whose card recorded it as a separate finding and asked to leave the wording alone there.

## Done when

- A session with no tools gets recovery and final-pass prompts that ask only for the final answer; a session with tools keeps today's wording.
- Hermetic unit tests cover both; `swift build --build-tests` and `swift test` are green.