---
assignees:
- claude-code
position_column: todo
position_ordinal: a480
title: 'Router: the repetition watch does not read tool-call arguments, so a repeated runCode snippet is never stopped'
---
## What
Report (multitool session, 2026-09-26; multitool task 01M3ETVQGBG0R25ED1ER77ER9Z, router at c208add): in a live multitool run, a `runCode` tool call whose generated snippet had 160 or 200 repeated lines never finished (test limits of 20 and 45 minutes). The session used the default `RepetitionDetection` (on, minimum line length 20). No `repetitionStopped` event and no `FinishReason.repeatedLines` came. A 30-line snippet answered normally.

Cause found in the code: `RepetitionDetector.attemptTexts(in:excluding:)` (`Sources/FoundationModelsRouter/Session/RepetitionDetector.swift:41-57`) watches only `.reasoning` and `.response` entries. It returns `nil` for `.toolCalls`. `RoutedSessionActorRepetitionWatch.trimmed` (`RoutedSessionActorRepetitionWatch.swift:80`) also leaves `.toolCalls` unchanged. Thus text that the model generates into a tool-call argument is never watched. A second problem: in the arguments, the snippet is a JSON string, so its line breaks are `\n` escapes, and the detector splits only on a real line feed (`RepetitionDetector.swift:127`).

Steps:
- First, find out if the backend shows a `.toolCalls` entry (with its partial arguments) in the live transcript while the model generates it, or only after the call is complete. Write the answer in the task comment. If the arguments are visible only after the call ends, the watch cannot stop the generation; then record this, and the fix is a limit on the length of the generated arguments, or a watch on the raw token stream. Decide it from what you find.
- Make the watch read the text of the tool-call arguments of the attempt in flight. For a JSON string value, decode the escapes (at least `\n`) before the line split, so that a repeated line in a snippet counts as a repeated line.
- When the watch stops a call during a tool call, the result is the same as today for a repeated response: the `repetitionStopped` event and `FinishReason.repeatedLines`. The partial tool call must not run.
- Keep the behavior for `.reasoning` and `.response` the same.

## Acceptance Criteria
- [ ] A scripted backend that streams a tool call whose argument holds a repeated snippet (for example 200 equal lines of more than 20 characters, as `\n` escapes in a JSON string) is stopped with `FinishReason.repeatedLines`, and the tool does not run.
- [ ] A tool call with a 30-line snippet of different lines is not stopped.
- [ ] The watch of `.reasoning` and `.response` does not change.
- [ ] `swift build` passes with no warnings on a clean build.

## Tests
- [ ] Add tests in `Tests/FoundationModelsRouterTests/` next to the current repetition tests, for the cases above, with a scripted backend and no real model.
- [ ] Add a detector unit test: a JSON string with `\n` escapes splits into lines.
- [ ] `swift test` passes, and the output shows the full count of tests run.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #defect #limits