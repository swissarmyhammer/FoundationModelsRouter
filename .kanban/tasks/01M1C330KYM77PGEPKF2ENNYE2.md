---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1d3qxq19af4s3hs6g57x9z1
  text: |-
    ## How each README example was verified

    README.md holds three fenced code blocks. A script extracts them from the file
    itself, so each check reads the shipped text and not a copy.

    Script: `extract_readme_blocks.py` (scratchpad). It writes `block-1.swift`,
    `block-2.swift` and `block-3.sh`.

    ### Block 1 — the usage example (47 lines, Swift)

    Compiled as a real SwiftPM target. A temporary `.executableTarget` named
    `ReadmeCheck` was added to `Package.swift` at path `Examples/ReadmeCheck`, with
    the same dependencies as `MultiModelGeneration`. The extracted block was copied
    in as `main.swift`.

    ```
    cp scratchpad/blocks/block-1.swift Examples/ReadmeCheck/main.swift
    swift build --target ReadmeCheck
    Build complete! (4.90 sec)   exit 0
    ```

    The target and the directory were both removed after the check. `Package.swift`
    is byte-identical to its committed state again.

    ### Block 2 — the install line (1 line, Swift)

    The extracted line was inserted verbatim into the `dependencies:` list of a
    throwaway manifest in the scratchpad. `swift package dump-package` compiles and
    evaluates a manifest, so this is a real compile of the snippet.

    ```
    cd scratchpad/ManifestCheck && swift package dump-package
    manifest_exit=0
    ```

    The URL and the branch were checked separately:

    ```
    git ls-remote --heads https://github.com/swissarmyhammer/FoundationModelsRouter main
    b4e8dcb2e601efa81d9794fa319d33151da4e407  refs/heads/main
    ```

    ### Block 3 — the test commands (8 lines, sh)

    This block is shell, not Swift, so a compiler cannot read it. Two checks stand
    in for one:

    1. Syntax: `bash -n scratchpad/blocks/block-3.sh` — exit 0.
    2. Meaning: each of the three commands was resolved against the real packages.
       - `swift test` — run, exit 0. See the test comment below.
       - `swift test --package-path IntegrationTests` — `swift test list
         --package-path IntegrationTests` built that package and listed 31 tests, so
         the path and the package are both good. The full run is not made here: it
         downloads real weights and takes tens of minutes.
       - The `--filter` command — the README regex was applied to those same 31
         listed ids. It matches 5 tests across the three named suites
         (`AutoCompactionTriggerIntegrationTests`, `CompactionSmokeIntegrationTests`,
         `RecordedTranscriptCompactionIntegrationTests`). swift-testing filters on
         the same ids `list` prints, so the command cannot match nothing.

    ### Prose claims checked beside the blocks

    - `Tests/FoundationModelsRouterTests/ExamplesTests.swift` exists.
    - `Examples/MultiModelGeneration` exists.
    - `IntegrationTests/Package.swift` declares both target names the prose states.
  timestamp: 2026-08-31T23:51:14.401309+00:00
- actor: claude-code
  id: 01m1d3rh7mtkdjh99yavtcc4js
  text: |-
    ## What was broken, and what each break was

    Block 1 held three separate breaks. Blocks 2 and 3 held none.

    ### Break 1 — the reported one: a wrong argument label

    ```
    error: missing argument label 'profile:' in call
    ```

    `Router.resolve` is `resolve(profile:reporting:)`
    (`Sources/FoundationModelsRouter/Router.swift`, `public func resolve`). The
    example called `resolve(coding, reporting: progress)`. Corrected to
    `resolve(profile: coding, reporting: progress)`.

    ### Break 2 — `recordingsDir` was never declared

    ```
    Examples/ReadmeCheck/main.swift:5:20: error: cannot find 'recordingsDir' in scope
    ```

    The example passes `recordingsDir: recordingsDir` to `Router.init`, but nothing
    in the block declares that name. A reader who copies the block gets an error on
    the first statement. Added a declaration, and `import Foundation` for `URL`:

    ```swift
    // The router records every transcript under this directory.
    let recordingsDir = URL.documentsDirectory.appending(path: "RouterTranscripts")
    ```

    ### Break 3 — three missing imports the macros need

    The block imported only `FoundationModelsRouter` and `MLXHuggingFace`. The two
    macros expand into code that names three more modules:

    ```
    macro expansion #hubDownloader:37:3: error: cannot find 'HubClient' in scope
    macro expansion #hubDownloader:5:12: error: cannot find type 'HuggingFace' in scope
    macro expansion #hubDownloader:5:38: error: cannot find type 'MLXLMCommon' in scope
    macro expansion #huggingFaceTokenizerLoader:11:38: error: cannot find 'Tokenizers' in scope
    ```

    Added `import HuggingFace`, `import MLXLMCommon` and `import Tokenizers`. The
    import list now matches `Examples/MultiModelGeneration/main.swift`, which builds
    the same live loader. `Package.swift` already states this rule in the comment
    above `huggingFacePackage`.

    ### One thing checked that turned out correct

    `session.respond(to:)` has two candidate overloads: one returns `String`, the
    other returns `TurnOutcome` with defaulted parameters. `print(answer)` accepts
    either, so a compile alone does not settle it. A probe line
    `let answerIsAString: String = answer` was appended to the harness and it built,
    so `answer` is a `String` and `print(answer)` prints the reply. The probe was
    then removed.

    ## Not built, as the card asks: what a standing check would cost

    A permanent `ReadmeSnippets` executable target that compiles block 1 on every
    build. The cost:

    - One `.executableTarget` in `Package.swift` (about 6 lines) plus a directory
      holding one generated `main.swift`.
    - The block must stay a whole program. Today it is one. A future example that is
      a fragment would need a wrapper, or a marker that says which blocks compile.
    - Either the file is generated by a script in CI, or it is checked in and drifts
      from README.md. A checked-in copy needs a test that compares it to the block,
      which is a second moving part.
    - Build time: the target links the MLX and Hub products, so a cold build pays for
      them. Warm, this measured about 5 seconds.
    - It cannot check block 2 (a manifest fragment) or block 3 (shell). Those still
      need the two checks used here.

    Recommendation: build it only if README.md gains more Swift examples. For one
    example, the cheaper guard is to run the extract-and-compile check by hand when
    the public API changes.
  timestamp: 2026-08-31T23:51:34.388198+00:00
- actor: claude-code
  id: 01m1d3rrvp3jekcr1djx6w7cmh
  text: |-
    ### implement — changed

    - files: 1 changed — `README.md` (11 lines added, 1 line replaced).
      `Package.swift` was edited for the compile harness and then restored. `git
      diff Package.swift` is empty.
    - examples: 3 checked. 1 broken, with 3 separate breaks in it. 2 correct.
    - `swift build --target ReadmeCheck` on the extracted block 1: `Build complete!`,
      exit 0.
    - `swift package dump-package` on the extracted block 2: exit 0.
    - `bash -n` on the extracted block 3: exit 0. All three commands resolved against
      the real packages.
    - `swift test`: 1136 tests in 126 suites passed with 2 known issues, plus 83
      tests in 10 suites passed. exit 0. This matches the baseline.
    - One run out of three failed on a flake in
      `TurnCancellationTests.swift` line 950. No Swift file changed under this card,
      so the flake is not from this work. Carded as ^bqj719z.
    - next: `/review`.
  timestamp: 2026-08-31T23:51:42.198493+00:00
- actor: claude-code
  id: 01m1d4fffq7fn1gq8z9crtm5qn
  text: |-
    ### review — findings

    - command: `review sha 3025c92`. counts: 0 findings, 0 confirmed, 0 refuted, 0 files reviewed.
    - The engine gave no coverage. No validator declares a `*.md` match glob, so a
      README-only commit reaches no validator. The reviewer compiled the blocks by hand.
    - compile result, obtained by the reviewer: the corrected block 1 builds.
      `swift build --target ReadmeCheck` printed `Build complete! (3.59 sec)`, exit 0.
      The pre-change block fails in the same harness, exit 1, so the harness discriminates.
    - The three claimed breaks are each real and each necessary. Removing any one of them
      breaks the build. All six imports carry load. The added comment states the truth:
      the macro expansion names `MLXLMCommon`.
    - Blocks 2 and 3 are correct, as the implementer claimed.
    - findings: 3 open — README.md:15, README.md:18, README.md:24.
    - `Package.swift` is restored. `git diff Package.swift` is empty, and the tree holds
      no part of the experiment.
    - next: correct the Install block and the passive clause, then review again.
  timestamp: 2026-09-01T00:04:06.263552+00:00
- actor: claude-code
  id: 01m1d4gm11d1e3jv981n8xkmbm
  text: |-
    ### finish iteration 1 — findings
    - implement: changed — 1 file (README.md). 3 examples checked by compiling. 1 broken, with 3 breaks.
    - test: green — swift test, 1136 tests in 126 suites + 83 tests in 10 suites, exit 0
    - commit: 3025c92
    - review: findings — 3 open. README.md:15, :18, :24.

    The review found the repair incomplete, from the reader's position rather than
    from ours. The implementer compiled block 1 inside a target that already links
    `swift-huggingface` and `swift-transformers`. A reader has no such target. The
    reviewer built a consumer package that declares only what the Install block at
    `README.md:72` instructs, and the example failed:

        error: unable to resolve module dependency: 'HuggingFace'
        error: unable to resolve module dependency: 'Tokenizers'
        exit 1

    `MLXHuggingFace` and `MLXLMCommon` resolve through the router package.
    `HuggingFace` and `Tokenizers` do not, because the router target links neither
    product. Only the example and test targets of this package do. The reviewer
    added both packages to the consumer manifest and the example then built, so the
    correction is measured and not a guess.

    This is the same class of defect the card was written for: the example is
    correct for us and wrong for a reader. Note it for the next round.

    Also recorded: the review engine reviewed 0 files. No validator of the 13
    declares a match glob for `*.md`, so a README-only commit reaches no validator.
    The engine's zero was not a pass. The reviewer compiled the blocks by hand.
  timestamp: 2026-09-01T00:04:43.681805+00:00
- actor: claude-code
  id: 01m1d518s6ffbsfxyhpc44t427
  text: |
    ## The three findings, and what each one needed

    ### `README.md:15` and `README.md:18` — the Install block was incomplete

    The Install block named one package. The example imports `HuggingFace` and
    `Tokenizers`. Neither module reaches a reader's target through the router
    package, because the router target links neither product.

    The Install section now states two things, not one.

    First, the reader adds three packages to the `dependencies` list:

    ```swift
    .package(url: "https://github.com/swissarmyhammer/FoundationModelsRouter", branch: "main"),
    .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
    .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ```

    Second, the reader links three products from the target:

    ```swift
    .product(name: "FoundationModelsRouter", package: "FoundationModelsRouter"),
    .product(name: "HuggingFace", package: "swift-huggingface"),
    .product(name: "Tokenizers", package: "swift-transformers"),
    ```

    The two version bounds match `Package.swift` exactly. That manifest pins
    `swift-huggingface` at `from: "0.9.0"` and `swift-transformers` at
    `from: "1.3.0"`.

    Prose follows the second block. It tells the reader why the target must link
    both products, so a reader who skips a block knows what broke.

    ### `README.md:24` — passive voice

    Old text: "so all three are imported above".
    New text: "The example imports all three modules above."

    The sentence is now active. It is 8 words. It carries one idea.

    ## The tree

    `git diff Package.swift` is empty. `git status --porcelain` lists `README.md`
    and the kanban files alone. The harness lives in the scratchpad, outside the
    repository.
  timestamp: 2026-09-01T00:13:49.222990+00:00
- actor: claude-code
  id: 01m1d51p4gtn4s2x09ahj03ztr
  text: |
    ## Verified from the reader's position, not from ours

    The last round compiled the example inside this package. That proved nothing,
    because this package links more than a reader gets. This round builds a
    consumer package instead.

    ### The harness reads the shipped README, not a copy

    `build_reader_package.py` (scratchpad) reads `README.md` and finds the fenced
    blocks. It writes a package from three of them, and it adds nothing else:

    - block 0 becomes `Sources/ReaderCheck/main.swift`
    - block 1 becomes the manifest `dependencies` list
    - block 2 becomes the target `dependencies` list

    The manifest carries the package name, `platforms: [.macOS("27.0")]` and the
    target path. A reader supplies those for any package. The script adds no
    dependency and no product of its own. So the build measures exactly what the
    Install section instructs.

    ### The acceptance test passes

    ```
    cd scratchpad/FromReadme && swift build
    Build complete! (29.62 sec)
    exit 0
    ```

    ### Both controls fail, so both instructions carry load

    Control 1 — the old Install block. The consumer declares the router package
    alone, and links its product alone:

    ```
    error: .../main.swift:3:8 unable to resolve module dependency: 'HuggingFace'
    error: .../main.swift:6:8 unable to resolve module dependency: 'Tokenizers'
    exit 1
    ```

    This reproduces the reviewer's failure exactly.

    Control 2 — the packages declared, the products not linked. The consumer
    declares all three packages, and the target links the router product alone:

    ```
    error: .../main.swift:3:8 unable to resolve module dependency: 'HuggingFace'
    error: .../main.swift:6:8 unable to resolve module dependency: 'Tokenizers'
    exit 1
    ```

    This is the finding a reader would hit next. A `dependencies` entry alone does
    not link a module. The second code block in the Install section answers it.

    ### What this teaches about the two module classes

    `MLXHuggingFace` and `MLXLMCommon` need no entry. The router target links both
    products, and Swift lets a consumer import a transitively linked module.
    `HuggingFace` and `Tokenizers` are different: the router target links neither,
    so only the reader's own target can supply them.
  timestamp: 2026-09-01T00:14:02.896671+00:00
- actor: claude-code
  id: 01m1d51wrhtkd69b9c6e1jvqms
  text: |
    ### implement — changed

    - files: 1 changed — `README.md`. The Install section grew from one block to two
      blocks plus prose. One comment line in the example became active voice.
    - findings: 3 of 3 closed. `README.md:15`, `README.md:18`, `README.md:24`.
    - acceptance test: a consumer package generated from the shipped README blocks
      alone. `cd scratchpad/FromReadme && swift build` printed
      `Build complete! (29.62 sec)`, exit 0.
    - control 1 (the old Install block): exit 1, `unable to resolve module
      dependency: 'HuggingFace'` and `'Tokenizers'`.
    - control 2 (packages declared, products not linked): exit 1, the same two
      errors. Both Install blocks carry load.
    - `swift test`: 1136 tests in 126 suites passed with 2 known issues, plus 83
      tests in 10 suites passed. exit 0. This matches the baseline.
    - `git diff Package.swift` is empty. No harness reached the repository.
    - next: `/review`.
  timestamp: 2026-09-01T00:14:09.681626+00:00
- actor: claude-code
  id: 01m1d5nhyr1fkspq4xcsba47we
  text: |
    ## Round 2 review — independently verified from the reader's position

    The engine gave no coverage again. `review sha HEAD~1..HEAD` reported 0 findings
    over 0 files. `README.md` matched no validator, because no validator declares a
    `*.md` match glob. That zero is not a pass. This reviewer built the consumer
    package again, and did not reuse the implementer's harness or numbers.

    ### Every implementer claim was checked, and each one holds

    **Version bounds match the manifest.** `Package.swift` declares
    `swift-huggingface` at `from: "0.9.0"` and `swift-transformers` at
    `from: "1.3.0"`. The README states the same two bounds.

    **The acceptance test passes.** A throwaway consumer package in the scratchpad
    declares the three packages from the first Install block, and links the three
    products from the second block:

    ```
    cd scratchpad/consumer && rm -rf .build Package.resolved && swift build
    Build complete! (30.05 sec)
    exit 0
    ```

    SwiftPM resolved the router at remote `main` (b4e8dcb). That commit is one
    behind local HEAD, but commits 3025c92 and 025f84c change `README.md` and the
    kanban files alone. The library source is the same, so the build measures the
    example against the current API.

    **Control A fails: the old Install block.** The consumer declares the router
    package alone and links its product alone:

    ```
    error: .../main.swift:3:8 unable to resolve module dependency: 'HuggingFace'
    error: .../main.swift:6:8 unable to resolve module dependency: 'Tokenizers'
    exit 1
    ```

    **Control B fails: the products not linked.** The consumer declares all three
    packages, but the target links the router product alone:

    ```
    error: .../main.swift:3:8 unable to resolve module dependency: 'HuggingFace'
    error: .../main.swift:6:8 unable to resolve module dependency: 'Tokenizers'
    exit 1
    ```

    Both blocks carry load. A `dependencies` entry alone does not link a module.

    A first run of control A reported `unable to resolve module dependency:
    'yyjson'`, which is a stale build cache and not the true error. Each control was
    then run again after `rm -rf .build Package.resolved`. The errors above come
    from the clean runs.

    **The passive clause is now active.** Commit 3025c92 wrote "so all three are
    imported above". This commit replaced it with "The example imports all three
    modules above." The sentence is active. It is 7 words.

    ### The three findings of round 1 are closed

    - `README.md:15` — closed. The Install section names `swift-huggingface` and its
      `HuggingFace` product. Control A and control B both prove the entry is needed.
    - `README.md:18` — closed. The Install section names `swift-transformers` and
      its `Tokenizers` product. The same two controls prove it.
    - `README.md:24` — closed. The clause is active voice.

    ### The added prose meets ASD-STE100

    Each added sentence is active, is under 20 words, and carries one idea.

    | Sentence | Words |
    |---|---|
    | The example above needs three packages. | 6 |
    | Add them to the `dependencies` list in `Package.swift`: | 8 |
    | Then link three products from your own target: | 8 |
    | The `#hubDownloader()` and `#huggingFaceTokenizerLoader()` macros expand to code that calls `HuggingFace` and `Tokenizers`. | 13 |
    | Your target must link both products. | 6 |
    | The router package does not link them for you. | 9 |
    | The example imports all three modules above. | 7 |

    ### One observation, outside the scope of this commit

    The Install section never states the macOS 27.0 platform floor. A control that
    declares exactly what the section instructs, and adds no `platforms:` line,
    fails:

    ```
    error: The package product 'FoundationModelsRouter-product' requires minimum
    platform version 27.0 for the macOS platform, but this target supports 12.0
    exit 1
    ```

    This is not a finding on this commit. A diff review reports only on the lines
    the change added or modified, and no added line carries a platform claim. The
    gap is also older than the change: the previous text, "Add the package to
    `Package.swift`:", was equally silent. The Install section gives manifest
    fragments rather than a whole manifest, so the reader already supplies `name:`,
    `targets:` and a tools version. The platform floor sits in that same class, and
    SwiftPM names the needed version in its error.

    A separate card can add the floor to the Install section. This reviewer did not
    create one.

    ### The tree

    `git diff Package.swift` is empty. `git status --porcelain` lists kanban files
    alone, and no `README.md`. Every build ran in the scratchpad, outside the
    repository.
  timestamp: 2026-09-01T00:24:53.976100+00:00
- actor: claude-code
  id: 01m1d5ntqdqkky8y1hcfmz2sga
  text: |
    ### review — clean

    - command: `review sha HEAD~1..HEAD` (commit 025f84c). counts: 0 findings, 0
      confirmed, 0 refuted, 0 files reviewed. `README.md` matched no validator, so
      the engine gave no coverage. The reviewer verified by hand.
    - acceptance test, obtained by this reviewer: a consumer package that declares
      only the two Install blocks. `swift build` printed
      `Build complete! (30.05 sec)`, exit 0.
    - control A (the old Install block): exit 1, `unable to resolve module
      dependency: 'HuggingFace'` and `'Tokenizers'`.
    - control B (packages declared, products not linked): exit 1, the same two
      errors. Both Install blocks carry load.
    - version bounds: `Package.swift` declares `swift-huggingface` `from: "0.9.0"`
      and `swift-transformers` `from: "1.3.0"`. The README matches.
    - prose: every added sentence is active, is under 20 words, and carries one
      idea. The passive clause of 3025c92 is now active.
    - findings: 0 new. The 3 findings of round 1 are closed, and each closure was
      measured rather than accepted.
    - `git diff Package.swift` is empty. No harness reached the repository.
    - next: none. The card moves to done.
  timestamp: 2026-09-01T00:25:02.957225+00:00
- actor: claude-code
  id: 01m1d5q1cwpt6ensdrgzcc1agp
  text: |-
    ### finish iteration 2 — clean
    - implement: changed — 1 file (README.md). All 3 findings closed.
    - test: green — swift test, 1136 tests in 126 suites + 83 tests in 10 suites, exit 0
    - commit: 025f84c
    - review: clean — 0 new findings. Task moved to done.

    Card summary: 2 rounds, 6 findings, all fixed. The card asked for one wrong
    label. The work found four defects.

    The lesson worth keeping: round 1 made the example compile INSIDE this package,
    where the targets link more than a reader gets. Round 2 built a consumer package
    that declares only what the Install section instructs. That build is the correct
    acceptance test, and it failed until the Install section named the products.

    Both reviews reported 0 findings over 0 FILES. No validator of the 13 declares a
    match glob for `*.md`. A README-only commit reaches no validator, so the engine
    cannot pass or fail it. Each reviewer compiled by hand instead.
  timestamp: 2026-09-01T00:25:42.556663+00:00
position_column: done
position_ordinal: ffffaf80
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
- [x] The line 41 example compiles.
- [x] Every other code example in README.md is compiled, not read, and each is either
      correct or corrected.
- [x] The card records HOW each was verified, so a later reader knows the check was
      real.

## Tests
- [x] Compile each example. Paste the command and its result on the card.
- [x] Run `swift test`. All tests pass.

## Note

Reported by the FoundationModelsACPAgent session, verified here before carding:
README.md:41 against Router.swift:228. #router #docs #defect

## Review Findings (2026-08-31 19:12)

> Scope: `review sha 3025c92` — the diffs only.
> The validator fleet reviewed 0 files. No validator declares a `*.md` match
> glob, so the engine gives a README-only commit no coverage. Its zero count is
> absence of coverage, not evidence of correctness. The reviewer compiled the
> code blocks directly to get the findings below.

- [x] `README.md:15` `docs/install-completeness` — This change adds `import HuggingFace`, but the Install block at `README.md:72` names only the router package. A reader who obeys that block cannot build the example. The compiler reports `unable to resolve module dependency: 'HuggingFace'`. Add `swift-huggingface` (`from: "0.9.0"`) to the Install block, and name its `HuggingFace` product.
- [x] `README.md:18` `docs/install-completeness` — This change adds `import Tokenizers`, but the Install block at `README.md:72` names only the router package. A reader who obeys that block cannot build the example. The compiler reports `unable to resolve module dependency: 'Tokenizers'`. Add `swift-transformers` (`from: "1.3.0"`) to the Install block, and name its `Tokenizers` product.
- [x] `README.md:24` `docs/ste-active-voice` — The clause "so all three are imported above" is passive. Simplified Technical English requires active voice. Write a new sentence in active voice: "The example imports all three modules above."

### How the reviewer verified the findings

The reviewer did not read the blocks. The reviewer compiled them.

`awk` found three fenced blocks in the committed README.md: Swift at lines
12-60, Swift at lines 71-73, and shell at lines 91-100. This agrees with the
implementer's count.

**Block 1 compiles inside this package.** `sed -n '13,59p' README.md` extracted
the block. A temporary `ReadmeCheck` executable target compiled it:

```
swift build --target ReadmeCheck
Build complete! (3.59 sec)   exit 0
```

The harness discriminates. The pre-change block fails in the same harness with
`cannot find 'recordingsDir' in scope`, exit 1.

**Each of the three repairs is necessary.** The reviewer removed one repair at a
time from the fixed block. Each removal breaks the build:

| Removal | Exit |
|---|---|
| the `profile:` label | 1 |
| the `recordingsDir` declaration | 1 |
| the three added imports | 1 |

**Every import carries load.** The reviewer removed each import alone. All six
removals break the build, so the block holds no unused import.

**The added comment states the truth.** A minimal program that holds only the
two macros, without `import MLXLMCommon`, fails with
`macro expansion #hubDownloader:5:38: error: cannot find type 'MLXLMCommon' in
scope`. The macros do name all three modules.

**Block 1 fails for a reader who obeys the Install block.** The reviewer built a
throwaway consumer package that declares the router package alone, exactly as
`README.md:72` instructs, and pasted the block in:

```
error: unable to resolve module dependency: 'HuggingFace'
error: unable to resolve module dependency: 'Tokenizers'
exit 1
```

`MLXHuggingFace` and `MLXLMCommon` resolve through the router's own target
dependencies. `HuggingFace` and `Tokenizers` do not, because the router target
links neither product. Only the package's example and test targets link them.

**The proposed repair works.** The same consumer package, with
`swift-huggingface` and `swift-transformers` added, builds the block:

```
Build complete! (10.14 sec)   exit 0
```

**Block 2 is correct.** `git ls-remote --heads origin main` returns
`b4e8dcb2e601efa81d9794fa319d33151da4e407`, so the URL and the branch both
resolve.

**Block 3 is correct.** `swift test --package-path IntegrationTests list` lists
34 tests. The README regex matches 5 of them, across the three named suites.
The command cannot match nothing.

**The tree is clean.** `git diff Package.swift` is empty, `Examples/` holds only
`CompactionDemo` and `MultiModelGeneration`, and README.md matches HEAD.

### A note on the example as documentation

The example still demonstrates what it set out to demonstrate. The change added
lines; it removed no step. Resolution, the progress stream, a session, a turn
and the release all remain.