---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzrmezqyamqxscq29k503kxa
  text: |
    ### What was done, and the two decisions in it

    **The protocol rename is the cause removal.** `RunEventFunnel.post(_:)` could not be labelled on its own — Swift matches a conformance by full name, labels included, so labelling only the conformer stops the build. The requirement `OperationEventSink.post(_:)` is therefore renamed to `post(event:)`, and with it the second conformer `SessionOutbox.post(_:)` (public), the five test sinks, and every call site: `sink.post(event:)` in `ToolContext`, `upstream.post(event:)` in `RunEventFunnel.enqueueUpstream(event:)`, and `outbox.post(event:)` in `SessionTreeRestoration` and the suites.

    **`ToolContext` keeps its own labels.** `ToolContext.post(_:)`, `progress(_:)` and `elicit(_:)` are callers of the sink, not conformers of it. No finding names them, and renaming them would be a second source-breaking public change with nothing behind it. An earlier pass renamed `ToolContext.post` by accident; that was reverted deliberately.

    **Doc references followed the code.** Every `` `post(_:)` ``, ``isRendered(_:)`` and ``wrapping(_:sessionID:mailbox:sink:configuration:)`` reference across sources and tests now names the new label, so no doc link points at a symbol that no longer exists. The references to `ToolContext/post(_:)` stay as they were, because that symbol did not change.

    ### Discovery: three findings, not one

    `^zn8n9md` ticked ten label findings but applied only the non-public seven. All three public ones — `isRendered(_:)`, `wrapping(_:...)` and `post(_:)` — were still open in the code although the card showed them closed. This card applies all three.

    ### Outside this package

    `FoundationModelsMultitool` conforms to `OperationEventSink` and will not build against this rename until it changes `func post(_ event:)` to `func post(event:)` in `Invocation/RunBinding.swift`. That repository has its own board.
  timestamp: 2026-08-11T14:43:42.462286+00:00
position_column: doing
position_ordinal: '80'
title: Apply the three public fluent-usage labels that ^zn8n9md ticked but waived
---
`^zn8n9md` closed with 13 findings ticked. Three of them were ticked but not applied. The commit `7210df0` records the reason: they are public API, and the batch had already shipped two source-breaking public renames.

The user gave a direct instruction to apply them.

## The three findings, word for word

- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:230` — First parameter label omitted on `isRendered` method without a value-preserving conversion. The method is a predicate/test function, not a type conversion, so per the fluent-usage rule it should label its parameter. Change to `public static func isRendered(text: String) -> Bool` to label the parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:681` — First parameter label omitted on `wrapping` static factory method without a value-preserving conversion. This is not a type conversion but a factory method decorating a tool with detachment behavior, so it should label its parameter. Change to `public static func wrapping(tool: any Tool, sessionID:, ...)` to label the first parameter.
- [x] `Sources/FoundationModelsRouter/Hosting/DetachingTool.swift:1044` — First parameter label omitted on `post` method without a value-preserving conversion. This is a side-effecting method posting an event (implementing OperationEventSink protocol), not a conversion operation. Change to `func post(event: OperationEvent) async` to label the parameter.

## Why the third one reaches further than its own line

`RunEventFunnel.post(_:)` is the conformance to the public protocol `OperationEventSink.post(_:)`. Swift matches a conformance by the full name, labels included. Thus you cannot label the conforming method alone — the code stops compiling. To remove the cause you must rename the protocol requirement itself.

The rename therefore also touches:

- `SessionOutbox.post(_:)`, which is public and is the other conformer;
- every `sink.post(...)`, `upstream.post(...)` and `outbox.post(...)` call site;
- the test sinks in five suites, which conform to the same protocol.

## Deliberately not renamed

`ToolContext.post(_:)`, `ToolContext.progress(_:)` and `ToolContext.elicit(_:)` keep their labels. They are callers of the sink, not conformers of it, and no finding names them. Renaming them is a separate public change with no finding behind it.

## Consequence outside this package

`OperationEventSink` is public and sibling packages conform to it. `FoundationModelsMultitool/Sources/FoundationModelsMultitool/Invocation/RunBinding.swift` implements `func post(_ event: OperationEvent) async`. That package needs the same one-line change. It has its own board, so the change belongs there, not here.

## Acceptance Criteria

- [x] All three findings applied, and every doc reference to a renamed symbol updated
- [x] Ungated `swift test` green, at or above the baseline of 811/77 + 27/11 + 24/5 with the one pre-existing `BoundedWait` known issue

#phase-1