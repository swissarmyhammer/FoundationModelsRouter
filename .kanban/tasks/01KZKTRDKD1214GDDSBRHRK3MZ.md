---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: RoutedSession's cancel/replace omit the first argument label, and its two elicitation methods duplicate the ULID parse
---
Surfaced by the `swift` + `missing-docs` validators while verifying `^6ejrrr7` (a doc-comment-only card). All four are pre-existing defects in `Sources/FoundationModelsRouter/Session/RoutedSession.swift` that `^6ejrrr7` deliberately did not touch: that card changes only ``…`` symbol-link text, and these are production signature/structure changes with callers.

Verbatim findings from `review file Sources/FoundationModelsRouter/Session/RoutedSession.swift --validators swift,missing-docs`:

- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:692` — The first parameter of `cancel(_:)` is unnamed, making the call read as `session.cancel(someId)` instead of the grammatically clearer `session.cancel(id: someId)`. Omitting the first argument label is only correct for value-preserving conversions (e.g., type conversions), not for operations on identifiers. The delegate call on line 693 uses the label (`outbox.cancel(id: id)`), so the wrapper should too. Change the signature to `public func cancel(id: SessionOutbox.ItemID) async` to make the call site read fluently: `session.cancel(id: someId)`.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:708` — The first parameter of `replace(_:prompt:)` is unnamed, making the first argument position read unclearly. Omitting the first argument label is only correct for value-preserving conversions (e.g., type conversions), not for operations on identifiers. The delegate call on line 709 uses the label (`outbox.replace(id: id, prompt: prompt)`), so the wrapper should too for consistency. Change the signature to `public func replace(id: SessionOutbox.ItemID, prompt: Transcript.Prompt) async` to match the delegate's labeled style and improve call-site clarity: `session.replace(id: someId, prompt: newPrompt)`.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:739` — ULID parsing logic duplicated at lines 739-741 and 760-762. Both `respond(elicitationId:response:)` and `complete(elicitationId:)` contain identical guard blocks that parse the elicitation ID string and return `.noPendingElicitation` on failure. This pattern could drift if one is changed without updating the other. Extract a shared helper that wraps the ULID parsing and delegates to the mailbox method: `private func parseElicitationIdOrReturnDefault<R>(_ elicitationId: String, defaultValue: R, operation: (ULID) async -> R) async -> R`, then call it from both methods with their respective mailbox operations and default return values.
- `Sources/FoundationModelsRouter/Session/RoutedSession.swift:760` — ULID parsing logic duplicated at lines 760-762 and 739-741 (see line 739 finding). See line 739 finding above.

## Notes for whoever picks this up

`cancel` and `replace` are `public` on `RoutedSession`, so renaming the first label is a source-breaking API change: sweep every caller (`get callgraph` inbound on both) and every ``…`` symbol link naming `cancel(_:)` / `replace(_:prompt:)`, since renaming the label changes the symbol name and would re-stale those links. `Scripts/check-doc-links.py` (added by `^6ejrrr7`) reports any link left behind — run it after the rename and expect exit 0.

Apply each finding's cause to the whole file rather than only the cited lines.

## Acceptance Criteria
- [ ] `cancel` and `replace` label their first parameter, and every caller and symbol link is updated with them
- [ ] The duplicated elicitation-id ULID parse exists in exactly one place
- [ ] `Scripts/check-doc-links.py` exits 0 afterward
- [ ] Ungated `swift test` stays green

## Tests
- [ ] Existing session tests cover both call paths; extend them only if the rename or the extraction leaves a path unexercised #phase-1