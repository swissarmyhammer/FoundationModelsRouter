---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: The README resolve example does not compile
---
## What

README.md line 41:

```swift
let profile = try await router.resolve(coding, reporting: progress)
```

The real signature is `resolve(profile:reporting:)` —
Sources/FoundationModelsRouter/Router.swift:228. The example omits the `profile:`
label, so it does not compile.

This is the first code a new consumer reads. A downstream session found it while
surveying the package to plan against it.

## What to do

Correct the call. Then check EVERY other code example in README.md the same way —
compile them, do not read them. One wrong label found by a reader means the file has
not been checked against the API in a while, and the rest of the examples are the same
age as this one.

If a cheap way exists to keep them honest — a test target that compiles the README
snippets, or a doc test — say what it would cost on the card. Do not build it under
this card without saying so.

## Acceptance Criteria
- [ ] The line 41 example compiles.
- [ ] Every other code example in README.md is compiled, not read, and each is either
      correct or corrected.
- [ ] The card records HOW each was verified, so a later reader knows the check was
      real.

## Tests
- [ ] Compile each example. Paste the command and its result on the card.
- [ ] Run `swift test`. All tests pass.

## Note

Reported by the FoundationModelsACPAgent session, verified here before carding:
README.md:41 against Router.swift:228. #router #docs #defect