---
assignees:
- claude-code
position_column: todo
position_ordinal: '8680'
title: The README Install section does not state the macOS 27 platform floor
---
## What

A reader who follows the Install section of `README.md` exactly cannot build.
The section does not say that the package needs macOS 27.

A consumer package that declares what the section instructs, and adds no
`platforms:` line, fails:

    error: The package product 'FoundationModelsRouter-product' requires
    minimum platform version 27.0 for the macOS platform, but this target
    supports 12.0
    exit 1

## Where this came from

Measured on 2026-09-01 during the review of `^2ennye2`. The reviewer built the
consumer package and got the error above.

The reviewer did not record it as a finding on that card, and the decision was
correct: the commit under review added no line that makes a platform claim, and
the gap is older than that change.

## The judgement to make first

The Install section gives manifest fragments, not a complete manifest. The
reader already supplies `name:`, `targets:` and a tools version. The platform
floor can belong to that same class of thing the reader supplies.

Two arguments against that view:

- SwiftPM names the necessary version in its error, so a reader can recover. But
  the reader must first try, fail, and read a message. The other fragments do
  not have this property, because a reader knows a package needs a name.
- macOS 27 is not a usual floor. A reader can reasonably think the package works
  on the macOS they have.

Decide which view is correct, then do the work.

## What to do

- Read the Install section as a reader with no knowledge of this package.
- Decide if the floor belongs in the Install section.
- If yes, state it. Do not state a version you have not read from
  `Package.swift`.
- If no, record why on this card and close it.

## Acceptance criteria

- [ ] A consumer package that declares ONLY what the Install section instructs
      builds, or the card records why the reader must supply the floor.
- [ ] Build the consumer package in the scratchpad. Do not verify inside this
      repository: this repository's own targets carry a platform floor that a
      reader does not get.
- [ ] Any version stated is read from `Package.swift`, not remembered.
- [ ] Prose is ASD-STE100 Simplified Technical English.

## Note

`^2ennye2` corrected three other defects of this same class: the example was
correct for us and wrong for a reader. Read that card's comments before you
start. The consumer-package method is described there. #defect #docs #router