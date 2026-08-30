---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Publish a way to mint a completion token
---
## What

`SessionMailbox.makeCompletionToken()` mints the identifier that names one run.
Commit `267994d` made the function internal, and card ^hqxc1tp made the actor
internal too.

Measured in this tree:

| symbol | 760ae89 | origin/main | now |
|---|---|---|---|
| `SessionMailbox` | `public actor` | `public actor` | `actor` |
| `makeCompletionToken()` | `public static func` | `static func` | `static func` |

So this break is live on `origin/main` now. It is not new. The build of the
consumer stops at an earlier error, thus the break is masked and not reported.

A package outside this one uses the function. FoundationModelsMultitool calls it in
its library, not only in its tests, at
`Sources/FoundationModelsMultitool/Capabilities/Shell/Execute.swift:218`:

```swift
let context = ToolContext.current
let commandID = context?.completionToken ?? SessionMailbox.makeCompletionToken()
```

That is the identity a shell command uses when it starts outside a session, where
`ToolContext.current` is `nil`. The consumer imports this package plain, with no
`@testable`.

## What to do

Add one public static function on `ToolContext`:

```swift
extension ToolContext {
    public static func makeCompletionToken() -> String
}
```

It calls the internal `SessionMailbox.makeCompletionToken()`.

`ToolContext` is the correct home. The caller reads `ToolContext.current` on the
line above, and uses this value when that is `nil`. So the two halves of one
decision stay on one type, and the call becomes:

```swift
let commandID = ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()
```

Keep `SessionMailbox` internal. Keep `makeCompletionToken()` on the mailbox
internal. This is the same shape as `ToolContext.mount(_:op:as:)` from ^zgzyhsj and
`TranscriptEvent.merged(under:)` from ^cdrxcyc: put the entry point on the public
type the caller holds already.

The documentation comment must say what the token is for, and that a caller inside
a tool call must prefer `ToolContext.current?.completionToken`, because that value
names the run the session already tracks. This function is only for a caller with
no ambient context.

## Acceptance Criteria
- [ ] `ToolContext.makeCompletionToken()` is public, with the documentation comment
      described above.
- [ ] The package makes no other symbol public. Measure with
      `swift-symbolgraph-extract -minimum-access-level public` before and after. The
      count goes up by one.
- [ ] `SessionMailbox` and `SessionMailbox.makeCompletionToken()` stay internal.
- [ ] The value has the same shape as the value the mailbox mints.

## Tests
- [ ] Add a test that two calls give two different tokens.
- [ ] Add a test that the token has the same shape as the token the internal
      function mints.
- [ ] Type-check a probe that imports the package without `@testable`, in the shape
      of the consumer's line: `ToolContext.current?.completionToken ?? ToolContext.makeCompletionToken()`.
- [ ] Run `swift test`. All tests pass.
- [ ] Run `swift build --package-path IntegrationTests --build-tests`. It builds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #router #api #hosting