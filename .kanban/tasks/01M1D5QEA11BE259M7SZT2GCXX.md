---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1emy5hx2khevhfdcdj3sg87
  text: |
    ## The judgement: the floor belongs in the Install section

    The card asks one question first. Do the manifest fragments of the Install
    section include the platform floor, or does the reader supply it?

    The answer is that the section must state the floor. Five reasons support this.

    **1. The other fragments are reader knowledge. The floor is package knowledge.**

    Every SwiftPM package has a name, a targets list and a tools version. A reader
    supplies those three from what a package IS. The reader needs no fact about
    this package to write them. The macOS floor is the opposite. It is a fact about
    this package alone, and no reader can derive it.

    **2. The absent floor has a wrong default. The other fragments have none.**

    A manifest with no `name:` does not compile. The reader learns at once. A
    manifest with no `platforms:` compiles, and SwiftPM applies macOS 12.0. The
    measured error names that number:

        error: The package product 'FoundationModelsRouter-product' requires
        minimum platform version 27.0 for the macOS platform, but this target
        supports 12.0

    A silent wrong default is a defect of the documentation, not of the reader.

    **3. The floor is a precondition of use, not only a manifest line.**

    macOS 27 is not a usual floor. A reader on macOS 26 cannot use this package at
    all. That fact must reach the reader before the reader starts work.

    **4. The recovery cost is high.**

    The error arrives only after full dependency resolution. The measured run
    cloned eleven packages and took 39 seconds warm. A cold run takes much longer.
    The README exists to save that time.

    **5. The counter-argument is weak.**

    The card records one argument against: SwiftPM names the necessary version in
    its error. That is true, but the reader must first try, fail and read a
    message. A README that lets a reader fail on purpose is not complete.

    The measured run also failed on two more products. `HuggingFace-product` and
    `Tokenizers-product` each need macOS 13.0. One floor of 27.0 answers all three.
  timestamp: 2026-09-01T14:10:59.261891+00:00
- actor: claude-code
  id: 01m1en3eq9wk3h569rg7h1e2de
  text: |
    ## Verified from the reader's position

    The harness reads the shipped `README.md`. It does not read a copy.

    `build_reader_package.py` (scratchpad) finds the fenced blocks and writes a
    consumer package from them. It classifies each Swift block by its content:

    | Block content | Role in the consumer manifest |
    |---|---|
    | `platforms:` | the `platforms:` clause |
    | `.package(url:` | the `dependencies` list |
    | `.product(name:` | the target `dependencies` list |
    | the first other Swift block | `Sources/ReaderCheck/main.swift` |

    The script adds only three things: a tools version, a package name and one
    target path. A reader supplies those three for ANY package. The script adds no
    package, no product and no platform of its own. A README with no `platforms:`
    block therefore produces a manifest with no `platforms:` clause.

    ### RED — the shipped README before the change

    A fresh directory, so no build cache can hide the result:

    ```
    rm -rf ReaderBefore
    python3 build_reader_package.py README.md ReaderBefore
    platforms block from README: None

    cd ReaderBefore && swift build
    error: The package product 'FoundationModelsRouter-product' requires minimum
    platform version 27.0 for the macOS platform, but this target supports 12.0
    error: The package product 'HuggingFace-product' requires minimum platform
    version 13.0 for the macOS platform, but this target supports 12.0
    error: The package product 'Tokenizers-product' requires minimum platform
    version 13.0 for the macOS platform, but this target supports 12.0
    error: Build failed
    exit 1
    ```

    This reproduces the card's measured error word for word. It also finds two more
    failures the card does not name. `HuggingFace` and `Tokenizers` each need macOS
    13.0. One floor of 27.0 answers all three.

    The run cloned eleven packages and took 39 seconds. That is the cost a reader
    pays before the error arrives.

    ### GREEN — the same harness on the corrected README

    ```
    rm -rf ReaderAfter
    python3 build_reader_package.py README.md ReaderAfter
    platforms block from README: 'platforms: [.macOS("27.0")],'

    cd ReaderAfter && swift build
    Build complete! (28.57 sec)
    exit 0
    ```

    The generated manifest carries the line the README now gives:

    ```swift
    let package = Package(
        name: "ReaderCheck",
        platforms: [.macOS("27.0")],
    ```

    ### The version is read, not remembered

    `Package.swift` declares:

    ```swift
        platforms: [
            .macOS("27.0")
        ],
    ```

    The README states the same string, `"27.0"`, in the same form.

    The consumer package resolved the router at `origin/main` (44af734), not at
    local HEAD (2a3e0c0). `git diff origin/main HEAD -- Package.swift` is empty, so
    the remote manifest declares the same floor. The build measured the floor the
    README states.

    ### The tree

    `git diff Package.swift` is empty. No harness reached the repository. Every
    build ran in the scratchpad.
  timestamp: 2026-09-01T14:13:52.489937+00:00
- actor: claude-code
  id: 01m1en3ravtbz0bf4424t6z8sx
  text: |
    ## The change, and the prose

    `README.md`, the Install section. The section now opens with the floor, because
    the floor is a precondition. A reader on macOS 26 must learn that first.

    ```
    ## Install

    The package needs macOS 27 or later. Declare that floor in your `Package.swift`:

    ```swift
    platforms: [.macOS("27.0")],
    ```

    SwiftPM applies macOS 12.0 when your manifest states no floor. The build then
    fails.
    ```

    The trailing comma matches the two blocks that follow. Each block is a fragment
    the reader pastes into a list or an argument list.

    ### Each added sentence meets ASD-STE100

    | Sentence | Words | Voice |
    |---|---|---|
    | The package needs macOS 27 or later. | 7 | active |
    | Declare that floor in your `Package.swift`: | 6 | active |
    | SwiftPM applies macOS 12.0 when your manifest states no floor. | 10 | active |
    | The build then fails. | 4 | active |

    Each sentence carries one idea. The `12.0` number is measured, not guessed. The
    RED build printed it.

    ### The review engine gives this file no coverage

    `dump validators` on `README.md` returned `rule_count: 0` and
    `validators: []`. No validator declares a `*.md` match glob, so a README-only
    change reaches no validator. A zero from the engine is absence of coverage, not
    a pass. This card was verified by building instead.
  timestamp: 2026-09-01T14:14:02.331362+00:00
- actor: claude-code
  id: 01m1en4322a08fw0n6bew5pca8
  text: |
    ### implement — changed

    - judgement: the floor BELONGS in the Install section. The other fragments are
      reader knowledge; the floor is package knowledge that no reader can derive.
      The absent floor also has a wrong silent default of macOS 12.0. Full
      reasoning is in the first comment.
    - files: 1 changed — `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/README.md`.
      The Install section gained one sentence pair, one fenced block and one
      consequence sentence.
    - RED, on the shipped README before the change: a consumer package generated
      from the README blocks alone, in a fresh directory. `swift build` printed
      `The package product 'FoundationModelsRouter-product' requires minimum
      platform version 27.0 for the macOS platform, but this target supports 12.0`,
      plus the same failure for `HuggingFace-product` and `Tokenizers-product` at
      13.0. exit 1.
    - GREEN, on the corrected README, same harness: `swift build` printed
      `Build complete! (28.57 sec)`, exit 0. A clean re-run confirmed exit 0.
    - version: `"27.0"` was read from `Package.swift`. `git diff origin/main HEAD --
      Package.swift` is empty, so the resolved remote declares the same floor.
    - `swift test`: 1159 tests in 128 suites passed with 2 known issues, plus 83
      tests in 10 suites passed. exit 0. This matches the baseline.
    - `git diff Package.swift` is empty. `git status --porcelain` lists `README.md`
      and the kanban files alone. No harness reached the repository.
    - next: `/review`.
  timestamp: 2026-09-01T14:14:13.314969+00:00
position_column: doing
position_ordinal: '80'
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

**Decided 2026-09-01: the floor belongs in the Install section.** The full
reasoning is the first comment on this card. In short: the other fragments are
reader knowledge, and the floor is package knowledge. The absent floor also has
a wrong silent default of macOS 12.0, where an absent `name:` has none.

## What to do

- Read the Install section as a reader with no knowledge of this package.
- Decide if the floor belongs in the Install section.
- If yes, state it. Do not state a version you have not read from
  `Package.swift`.
- If no, record why on this card and close it.

## Acceptance criteria

- [x] A consumer package that declares ONLY what the Install section instructs
      builds, or the card records why the reader must supply the floor.
- [x] Build the consumer package in the scratchpad. Do not verify inside this
      repository: this repository's own targets carry a platform floor that a
      reader does not get.
- [x] Any version stated is read from `Package.swift`, not remembered.
- [x] Prose is ASD-STE100 Simplified Technical English.

## Note

`^2ennye2` corrected three other defects of this same class: the example was
correct for us and wrong for a reader. Read that card's comments before you
start. The consumer-package method is described there. #defect #docs #router