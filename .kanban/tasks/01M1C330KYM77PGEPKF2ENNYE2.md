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
position_column: doing
position_ordinal: '80'
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