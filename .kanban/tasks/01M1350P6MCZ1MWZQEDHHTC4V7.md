---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m14bdykgdffaay8e6pdwwv02
  text: |-
    Research: how to build the documentation in this package.

    The DocC plugin is NOT in this package. `swift package generate-documentation` fails with `error: Unknown subcommand or plugin name 'generate-documentation'`, and `swift package plugin --list` shows no plugins. Package.swift has no `swift-docc-plugin` dependency, and the target excludes the `.docc` catalog from the build.

    The check that works is `xcrun docc convert` with a symbol graph. These are the steps:

    1. `swift build --target FoundationModelsRouter -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <sgdir>`
    2. Copy only `FoundationModelsRouter*.symbols.json` into a clean directory. The first directory also holds the symbol graphs of all dependencies, and DocC tries to document each one.
    3. `xcrun docc convert Sources/FoundationModelsRouter/FoundationModelsRouter.docc --fallback-display-name FoundationModelsRouter --fallback-bundle-identifier com.swissarmyhammer.FoundationModelsRouter --additional-symbol-graph-dir <sgdir> --output-path <outdir>`

    The symbol graph holds public symbols only, because `-emit-symbol-graph` uses a minimum access level of `public`. Thus a link to an internal symbol always gives an `... doesn't exist at ...` warning. This makes the run a correct test for this card.
  timestamp: 2026-08-28T14:12:26.352996+00:00
- actor: claude-code
  id: 01m14be83c0vznvqke5qkj0706
  text: |-
    The three links the card names are repaired in `Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md`. No source file changed its access level.

    RED, before the change: 110 warnings. Three of them named the card's symbols in `RoutedSession.md`:
    - `'isCancelled' doesn't exist at '/FoundationModelsRouter/ToolContext'` at RoutedSession.md:15
    - `'BackgroundToolRunner' doesn't exist at '/FoundationModelsRouter/RoutedSession'` at RoutedSession.md:26
    - `'RunToCompletionRunner' doesn't exist at '/FoundationModelsRouter/RoutedSession'` at RoutedSession.md:28

    The changes:
    - `ToolContext/isCancelled` becomes the plain code text `isCancelled`, with a sentence that says the property is internal. There is no public equivalent.
    - `BackgroundToolRunner` becomes `ToolMount/Mode/background`, and `RunToCompletionRunner` becomes `ToolMount/Mode/runToCompletion`. `ToolMount.Mode` is a public enum (Sources/FoundationModelsRouter/Hosting/ToolMount.swift), and its two cases carry the same meaning as the two internal runner types: one call returns a handle at once, the other runs to completion.

    GREEN, after the change: 107 warnings. The three warnings above are gone, and no new warning appeared.
  timestamp: 2026-08-28T14:12:36.076611+00:00
- actor: claude-code
  id: 01m14bf3gtnmkpqr5nwc2kwe79
  text: |-
    BLOCKER — the two acceptance criteria fight each other for four more links in the same file.

    Criterion 1 says `RoutedSession.md` has NO symbol link to an internal symbol. After the repair of the three named links, the file still has five broken links. This is the command and its output:

    ```
    $ xcrun docc convert Sources/FoundationModelsRouter/FoundationModelsRouter.docc \
        --fallback-display-name FoundationModelsRouter \
        --fallback-bundle-identifier com.swissarmyhammer.FoundationModelsRouter \
        --additional-symbol-graph-dir <sgdir> --output-path <outdir>

    warning: '(String)' isn't a disambiguation for 'enqueue(prompt:)' at '/FoundationModelsRouter/RoutedSession'
      --> RoutedSession.md:70:21-70:30
    warning: 'cancelPrompt(id:)' doesn't exist at '/FoundationModelsRouter/RoutedSession'
      --> RoutedSession.md:80:5-80:22
    warning: 'compact()' doesn't exist at '/FoundationModelsRouter/RoutedSession'
      --> RoutedSession.md:91:5-91:14
    warning: 'compact(prompt:)' doesn't exist at '/FoundationModelsRouter/RoutedSession'
      --> RoutedSession.md:92:5-92:21
    warning: 'compact(budget:)' doesn't exist at '/FoundationModelsRouter/RoutedSession'
      --> RoutedSession.md:93:5-93:21
    ```

    The cause: `Sources/FoundationModelsRouter/Session/RoutedSession.swift` line 317 declares `extension RoutedSession {` with NO access modifier. Swift gives such extension members `internal` access, so `compact()` (line 320), `compact(budget:)` (line 329) and `cancelPrompt(id:)` (line 365) are internal, and the public symbol graph does not hold them. The `enqueue(prompt:)-(String)` link points at the same internal extension. `compact(prompt:)` names a method that exists in no form; only `compact(prompt:budget:)` (line 107 of the protocol) exists.

    Why I stopped:
    - Criterion 2 says NO source file changes its access level in this task. But these three members read as public convenience API on a public protocol, so the correct repair looks like `public extension RoutedSession`. Criterion 2 forbids that repair.
    - The only other repair inside criterion 2 is to DELETE the four entries from the `## Topics` list. A Topics list accepts symbol links only, so plain text is not possible there. That deletion removes API from the page, and it is a decision this card does not give me.

    The one question for a person: for `extension RoutedSession` at RoutedSession.swift:317, do you want the extension made `public` (a new task, because this card forbids it), or do you want the four entries deleted from the Topics list of `RoutedSession.md`?

    The three links the card names are repaired and verified. Nothing else in this file is touched.
  timestamp: 2026-08-28T14:13:04.154408+00:00
- actor: claude-code
  id: 01m14bfq02tea3hd0hrt0sjv8d
  text: |-
    ### implement — stuck
    - evidence: 1 file — Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md. `xcrun docc convert` with a symbol graph: 110 warnings before, 107 after; the three warnings the card names are gone. `swift build`: Build complete. `swift package generate-documentation` is not available; the package has no DocC plugin.
    - gap: acceptance criterion 1 is not met. `RoutedSession.md` still links four internal members of the unmarked `extension RoutedSession` at RoutedSession.swift:317 (`compact()`, `compact(budget:)`, `cancelPrompt(id:)`, `enqueue(prompt:)-(String)`), and one link, `compact(prompt:)`, names a method that does not exist.
    - next: a person answers the question in the BLOCKER comment — make the extension `public` in a new task, or delete the four entries from the Topics list.
  timestamp: 2026-08-28T14:13:24.098484+00:00
position_column: doing
position_ordinal: '80'
title: Repair the DocC links that point at internal symbols
---
## What

Three symbol links in Sources/FoundationModelsRouter/FoundationModelsRouter.docc/RoutedSession.md name symbols that are `internal`, so they cannot resolve when DocC builds:

- ``BackgroundToolRunner``
- ``RunToCompletionRunner``
- ``ToolContext/isCancelled`` (internal at Sources/FoundationModelsRouter/Hosting/ToolContext.swift:40)

Rewrite each as plain text, or link a public symbol that carries the same meaning. Do not widen access to make a link resolve; the symbols are correctly internal.

Scope note: this task covers ONLY the three links above. `RoutedSession.md` holds four further broken links — `compact()`, `compact(prompt:)`, `compact(budget:)`, `cancelPrompt(id:)`, and a disambiguation warning on `enqueue(prompt:)`. Their cause is a separate defect: `extension RoutedSession` (Sources/FoundationModelsRouter/Session/RoutedSession.swift:317) carries no access modifier, so those convenience members are internal. Task ^hdabs7j fixes that, and it repairs those links. A `## Topics` list accepts a symbol link and not plain text, so those entries cannot be repaired here without deleting them.

## Acceptance Criteria
- [ ] `RoutedSession.md` has no symbol link to ``BackgroundToolRunner``, ``RunToCompletionRunner``, or ``ToolContext/isCancelled``.
- [ ] No source file changed access level for this task.
- [ ] The DocC warning count falls by exactly those three, with no new warning.

## Tests
- [ ] Build the documentation and compare the warning list before and after. The package has no DocC plugin, so use the symbol-graph route: `swift build --target FoundationModelsRouter -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <dir>`, then `xcrun docc convert` over the catalog with `--additional-symbol-graph-dir`.
- [ ] Run `swift build`. It succeeds.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #docs #router