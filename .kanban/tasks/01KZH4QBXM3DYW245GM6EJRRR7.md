---
assignees:
- claude-code
position_column: todo
position_ordinal: '8780'
title: Stale DocC symbol links in the split session files name signatures that no longer exist
---
Discovered while working `^5m97h14`'s iteration-3 review findings. Not one of those findings, and deliberately not fixed there: `^5m97h14`'s findings are about `- Parameter` doc *keys* and about magic numbers, and the `swift/doc-parameter-naming` rule explicitly separates the two concerns — "DocC symbol links follow the declaration, not this rule … do not 'fix' symbol links to internal names, and do not cite them as violations of this rule." These links are broken for a different reason: they name an argument list the declaration no longer has, so DocC resolves nothing at all.

## The six confirmed links

Each was verified against the declaration by grep, not inferred.

- `Sources/FoundationModelsRouter/Session/RoutedSessionActorRecording.swift` — ``recordTranscriptDelta(grammar:since:usage:)`` in `makePartialEvent`'s doc comment. Declared (same file) as `recordTranscriptDelta(grammar:since:usage:pendingEvents:onEvent:)` — the link is missing two labels.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``recordTranscriptDelta(grammar:since:usage:pendingEvents:)`` in `generate`'s doc comment. Missing `onEvent:`.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:)`` in `dispatchNextPrompt`'s doc comment. Missing `onEvent:`; declared in `RoutedSessionActorRecording.swift` as `finishTurnAndRequeueIfUnattached(grammar:since:usageBefore:pendingEvents:onEvent:)`. Note the *other* two links to this same symbol in the same file already spell it correctly, so this one is inconsistent with its own file.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorTurnExecution.swift` — ``generate(grammar:prompt:_:)``, twice. Declared as `generate(grammar:prompt:onEvent:_:)`.
- `Sources/FoundationModelsRouter/Session/RoutedSessionActorGeneration.swift` — ``generate(grammar:prompt:_:)``, once. Same defect.

All six predate the `RoutedSession.swift` split (`^5m97h14` iteration 2, commit `2adf089`) — the split moved them between files but did not create them; they went stale when `onEvent:` was added to those signatures.

## Do not trust a naive scanner here

A first pass at counting these module-wide reported 97 "stale" links in `Session/` alone. That number is wrong twice over: it counted enum-case links (``turnEnded(_:)``, ``toolCall(id:name:argumentsJSON:)``, ``compaction(_:)``) as unresolved because the collector only gathered `func` declarations, and its parameter-list splitter treated the `>` in a `->` closure return as a bracket close, so any signature with a closure parameter was mis-parsed. Whatever finds the rest of these must resolve enum cases, initializers, and properties too, and must parse closure parameter types correctly — or be checked by hand.

## Acceptance Criteria
- [ ] The six links above name the argument lists their declarations actually have
- [ ] The rest of the module is swept for the same defect with a method that does not produce the false positives described above — enum cases, initializers, and properties resolved, closure parameters parsed correctly
- [ ] No `- Parameter` doc key is changed by this work: this task is only about `` `` ``-delimited symbol links, and the rule forbids moving doc keys toward external labels
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Documentation-only change, so no behavioral test. If the sweep is mechanized, the checker itself is the durable artifact worth keeping. #phase-1