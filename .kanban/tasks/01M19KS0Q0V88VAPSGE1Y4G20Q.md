---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m1a7wa898g4ttkkg5k8svbeg
  text: |-
    ### Build the symbol-graph differ. Do not adopt the regex script.

    The card already said the symbol-graph version is the one worth building. A third
    session measured it, thus this is no longer a preference:

    ```
    swift build -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc <out>
    ```

    That is the SwiftPM route, not a hand-built `-I` list given to
    `swift-symbolgraph-extract`. It ran in 1.9 seconds and gave 176 public symbols for
    that package, with 19 Initializers, 37 Instance Methods and 14 Type Methods among
    them. It needs no flag archaeology, thus it also removes the stale-extract trap that
    ^kra1zs6 recorded.

    That session then checked the granularity against three real breaks, and did not
    assume:

    | change | how it shows |
    |---|---|
    | an initializer that lost an argument | a changed `declarationFragments` entry, on a symbol path that does not move |
    | a type method that was renamed | one path that goes, one path that arrives |
    | a type that was deleted | a Structure that goes |

    All three are visible. The regex script sees only the third.

    ### Why this matters for this package specifically

    Of the five breaks this card lists, four were MEMBERS, not types:
    `SessionMailbox.makeCompletionToken()`, `MergedTranscript.merged(under:)`, the
    `OperationEventSink` typealias, and `OperationEventSegment`. Only `ToolMounting` was a
    type going internal.

    A differ that matches type names would read clean on four of the five. It would have
    read `SessionMailbox` as safe while `makeCompletionToken` was already broken, which is
    the break that stayed hidden the longest. So shipping the regex script as the
    pre-flight check gives a check that passes on almost every failure this package has
    actually caused.

    Keep `scripts/symbolmap.py` for reference. Do not make it the gate.

    ### Scope

    Two other packages hit the same problem against two different producers, thus a differ
    that takes the two symbol-graph directories as arguments serves all three. Build it to
    take paths, not to name a consumer. Nothing about it is specific to this package.
  timestamp: 2026-08-30T21:05:49.321043+00:00
- actor: claude-code
  id: 01m1a99hrk0hchh8sqxm50mt8k
  text: |-
    ### Where the differ lives, and the strongest argument for it

    **Build it in the ranker package, not here.** That session measured the extraction
    route, the 1.9 seconds and the granularity, thus building a second one here would
    repeat their work. This card points at theirs. If they decline to own it, take it back.

    Requirements they state, and both are right:

    1. It must run against two revisions of ONE package, with no consumer checked out.
       "Does anyone name this?" and "did my public API change?" are different questions,
       and the second is the one that finds a changed signature.
    2. It must exit non-zero on a removal or a changed fragment, so it sits in a pre-push
       check instead of waiting for a person to remember it.

    Add to (2): make the exit code separate a removed symbol from a changed fragment, so a
    caller can stop on the first and warn on the second.

    ### The argument that is stronger than the one this card was written with

    Three sessions were wrong today, in three directions, and each was wrong about
    ANOTHER package's surface. That is the boundary no test suite covers. This package's
    tests prove this package works. The consumer's prove the consumer works. Nothing
    either one runs says anything about the seam between them, and all five breaks lived
    exactly there.

    That is the case for the differ living where all three packages can run it, rather
    than inside any one of them.

    ### The instrument, stated plainly

    Every correction today came from running something. Every wrong answer came from
    reading source text and reporting a conclusion. Twice the symbol graph found what
    reading missed:

    1. `SessionMailbox.makeCompletionToken()`, demoted inside a file whose name made it
       look like the actor's own surface.
    2. `RoutedSession.respond(elicitationId:response:)`, which two sessions read as
       internal because the line carries no `public` keyword. A protocol requirement never
       does. It takes the access level of the protocol, and the symbol was public the
       whole time.

    The second one matters most for this card. The differ is not only a way to catch a
    change that a text search misses. In a language where the access level of a
    declaration is not always written on its own line, reading the symbol graph is the
    only reliable way to answer "what is public" at all. The failure it prevents is a
    confident wrong answer, not a missing one. Put that in its documentation.

    ### The tracked script is fixed

    `scripts/symbolmap.py` took the fix the ranker made in their `552307c`:

    - `ROUTER` defaults to the repository holding the script, resolved two levels up from
      `__file__`, with `resolve()` first because `__file__` is relative under a relative
      call.
    - `CONSUMER` is required and has no default. A guessed consumer gives a clean report
      about a package nobody asked about, and that reads the same as a true all-clear.
    - Both paths are checked for `.git`, the failing argument is named, exit 2.
    - `--help` exits 0. No arguments exits 2.
    - `REV` defaults to `HEAD`, not `main`, because the surface being checked is the one
      about to land.

    Verified rather than assumed: no arguments exits 2; `--help` exits 0; a bad consumer
    path prints `CONSUMER_REPO: not a git repository: ...` and exits 2; and a run from
    `/tmp` through an absolute path to the script reports 235 type declarations at HEAD
    with 49 named by the consumer.

    The header of the file now states that it is reference material and NOT the gate, and
    says why: it matches type names only, thus four of the five real breaks are invisible
    to it.
  timestamp: 2026-08-30T21:30:31.571989+00:00
- actor: claude-code
  id: 01m1a9gm2y6y33sm1ma2bphb4a
  text: |-
    ### Correction: the ownership is NOT decided

    An earlier comment on this card said "build it in the ranker package, not here" as
    though the reasoning settled it. It does not. New work in another repository is that
    repository's user's decision, and a peer session cannot give that approval. The ranker
    session said so, and it was right to refuse.

    The true state: the ranker session has put the question to its user and is waiting.
    The reasoning for them owning it stands — they measured the extraction route and the
    granularity — but the decision does not exist yet.

    If their user declines, build it here. Do not wait indefinitely.

    ### A third exit state, from the ranker

    Better than the two states an earlier comment described:

    | change | exit | why |
    |---|---|---|
    | a symbol is removed | non-zero, hard fail | it breaks a consumer today |
    | a declaration fragment changes | non-zero, warn | it breaks only a consumer that uses what changed |
    | a symbol is added | zero, but reported | this is the line a release note is written from |

    ### The trap is in the language, not in this package

    The ranker checked their own package after reading the `RoutedSession` finding.
    `AgentSession` is a public protocol with three requirements, and not one carries a
    `public` keyword:

    ```
    func respond(to prompt: String) async throws -> String
    func fork() async throws -> any AgentSession
    func respond<T: Generable>(to prompt: String, generating type: T.Type) async throws -> T
    ```

    All three are public in the symbol graph. So two packages now show the same trap, and
    a keyword search reports "internal" for six public symbols across them.

    Thus the documentation must lead with "what IS public", and treat "what changed" as
    the second feature. The first is the difference between a correct answer and a
    confident wrong one.

    ### The script, corrected again

    Two more defects, both found by running the file rather than reading it:

    1. The no-argument path printed the usage text to STDOUT. A caller that pipes the
       report would receive usage mixed into it. Usage now goes to stderr when it explains
       an error, and to stdout when a caller asks for it with `--help`.
    2. The argument order did not match the ranker's copy. Two tracked copies of one
       reference script that take different command lines is a trap for a reader of both.
       This copy now takes the ranker's order exactly, including the one-argument form and
       the `SOURCES_SUBPATH` argument. The header says not to let them diverge.

    The earlier verification of this file checked the `--help` exit code with the output
    sent to `/dev/null`. It proved the exit code and proved nothing about the text. That
    is the same error this card exists to prevent, made while fixing another instance of
    it.

    Each path is now run, not reasoned about:

    ```
    no args     stdout 0 bytes, stderr 946 bytes, exit 2
    --help      stdout 946 bytes, exit 0
    bad path    "CONSUMER_REPO is not a git repository: /nope", exit 2
    1-arg       provider defaults to this repository, 235 types, 49 named
    4-arg       byte-identical to the 1-arg output
    ```
  timestamp: 2026-08-30T21:34:23.326144+00:00
- actor: claude-code
  id: 01m1a9k6k8va6n41z12fe1h6e3
  text: |-
    ### Neither of us found our own defect. Both of us found the other's.

    The stdout defect was in both tracked copies. The ranker measured theirs after reading
    the report of mine, and fixed it in `5ab7b1a`.

    ```
    before   no args   stdout 639, stderr 0,   exit 2   <- the defect
             bad path  stdout 0,   stderr 685, exit 2   <- already correct

    after    no args   stdout 0,   stderr 639, exit 2
             --help    stdout 639, stderr 0,   exit 0
             bad path  stdout 0,   stderr 685, exit 2
    ```

    One file held two error paths that disagreed with each other, and the author did not
    see it. Their commit message for `552307c` listed a test of the no-argument path and
    recorded the exit code alone. The stream never came up, in the same commit that wrote
    the test list out in full.

    Three copies of one defect between two sessions. **Neither session found the defect in
    its own file.** I found mine while reading their diff. They found theirs while reading
    my message. Not one instance was caught by its author testing its author's work.

    ### What that means for this card

    This card proposes a check that a package runs against itself before it lands a
    change. The evidence above says that shape has a limit: a check written and verified
    by one party inherits that party's blind spots, and a blind spot is not visible from
    the inside by definition. The three defects here were each found from the outside, by
    someone with no stake in the file being correct.

    So do not build the differ and treat "the author tested it" as sufficient. Two things
    follow:

    1. The differ must be run against a corpus with KNOWN answers that the author did not
       choose. The five real breaks recorded on this card are that corpus: four of them
       are member-level, thus a tool that measures type names passes all four while
       measuring nothing. A tool that reads clean on those four is broken, whatever its
       author measured.
    2. Whoever writes it, someone else runs it against that corpus and reports the result.
       That offer is open from this package regardless of who owns the tool.

    ### State of the two copies

    Both scripts now agree: same argument order, same one-argument form, same
    `SOURCES_SUBPATH`, same stream rules. Keep them that way. A divergence between two
    tracked copies of one reference script is a trap for whoever reads both, and this
    thread has already shown that the reader of the other copy is the one who finds the
    defects.
  timestamp: 2026-08-30T21:35:47.816775+00:00
- actor: claude-code
  id: 01m1agezk41rmw44ybk6q2wxe5
  text: |-
    ### The differ is built here, and it catches all five

    The ownership question the third comment left open never got an answer from the
    ranker's user, and the card says "If their user declines, build it here. Do not
    wait indefinitely." Built here.

    `scripts/symboldiff.py`, with `scripts/test_symboldiff.py` beside it and
    `Tests/FoundationModelsRouterTests/SymbolDiffScriptTests.swift` running those from
    the one unit target CI already runs. The guidance is `scripts/README.md`.

    ### The corpus, run rather than reasoned about

    Two pairs answer all five, and each exits 1:

    ```
    symboldiff.py FoundationModelsRouter . 6f0b2a8~1 6f0b2a8   exit 1, removed 10
    symboldiff.py FoundationModelsRouter . 267994d~1 267994d   exit 1, removed 20
    ```

    | break | pair | reported as |
    |---|---|---|
    | `ToolMounting` | 1 | `ToolMounting (swift.enum)` REMOVED |
    | `OperationEventSink` | 1 | `OperationEventSink (swift.protocol)` REMOVED, with its two requirements |
    | `SessionMailbox.makeCompletionToken()` | 1 | `SessionMailbox.makeCompletionToken() (swift.type.method)` REMOVED |
    | `MergedTranscript` | 2 | the enum AND `MergedTranscript.merged(under:)` REMOVED |
    | `OperationEventSegment` | 2 | the struct AND all seven of its members REMOVED |

    The acceptance criterion the card asked to prove is proved at the same ref: at
    `6f0b2a8` the one-revision form still lists `SessionMailbox (swift.class) actor
    SessionMailbox` on the public surface, while `makeCompletionToken()` is gone from
    it. The actor is public and the member is not, and the report says so.

    ### Two corrections to the card's own table, both measured

    `git grep` at each ref, rather than the table:

    - `SessionMailbox.makeCompletionToken()` was demoted at **6f0b2a8**, not 267994d.
      At `6f0b2a8~1` the line reads `public static func makeCompletionToken()`; at
      `6f0b2a8` it reads `static func`.
    - `OperationEventSegment` was demoted at **267994d**, not "before 267994d".
      `git log -S 'public struct OperationEventSegment'` names 267994d.

    The four revisions are consecutive: `4561f2a` -> `6f0b2a8` -> `1af7145` ->
    `267994d`.

    ### All three states seen on real data

    `267994d..HEAD` reports removed 240, changed 13, added 59, exit 1. The 13 changed
    rows are commit `377c1ee` "make default protocol implementations public": the slot
    went from one declaration to two. That is what the multiset of declarations for
    each `(path, kind)` slot buys — a protocol requirement and its extension default
    share a path and a kind, so a set would have collapsed them and reported nothing.

    ### What the card's ORIGINAL description asked for, and was not built

    The description's acceptance criteria name a consumer tree and a two-way split of
    consumer-named symbols. The comments overrule that in two places — "It must run
    against two revisions of ONE package, with no consumer checked out" and "Build it
    to take paths, not to name a consumer" — so the differ takes MODULE, PACKAGE_REPO
    and one or two revisions, and names no consumer. The consumer question stays with
    `symbolmap.py`, which still prints its three-section report and is now documented
    as reference material rather than a gate. This is a deliberate, comment-directed
    deviation, recorded here rather than left silent.
  timestamp: 2026-08-30T23:35:49.604716+00:00
- actor: claude-code
  id: 01m1agfq4q6798adfjjtrb66d7
  text: |-
    ### Measured, not assumed: the details a later reader needs

    **Every argument path was RUN, and both streams counted.** The card's own thread
    records three defects that came from checking an exit code alone, so each path was
    measured on stdout AND stderr:

    ```
    symboldiff.py  no args   stdout 0,    stderr 4600, exit 2
                   --help    stdout 4600, stderr 0,    exit 0
                   -h        stdout 4600, stderr 0,    exit 0
                   2 args    stdout 0,    stderr 4600, exit 2
                   5 args    stdout 0,    stderr 4600, exit 2
                   bad repo  stdout 0,    stderr 4645, exit 2, first line
                             "PACKAGE_REPO is not a git repository: /nope"

    symbolmap.py   no args   stdout 0,    stderr 1180, exit 2   (re-measured after
                   --help    stdout 1180, stderr 0,    exit 0    its header changed)
                   bad path  stdout 0,    stderr 1226, exit 2
    ```

    **The extraction, and what it costs.** `swift build --package-path <worktree>
    --scratch-path <dir> --target <module> -Xswiftc -emit-symbol-graph -Xswiftc
    -emit-symbol-graph-dir -Xswiftc <out>`, run over a detached `git worktree` of the
    commit. Measured on this package: 56 s for a revision it has not seen, under 0.2 s
    for one it has. The 1.9 s the earlier comment records was another, much smaller
    package; do not expect it here.

    **The MORE-THAN-ONE-FILE trap has a second half.** The card records
    `M.symbols.json` beside `M@ULID.symbols.json`. Measured here, a plain prefix match
    is worse than reading one file: this build writes
    `FoundationModelsRouterTestSupport.symbols.json` and
    `FoundationModelsRouterTestSupport@Swift.symbols.json` into the same directory, and
    a glob of `FoundationModelsRouter*` swallows three neighbouring modules. The read is
    `<M>.symbols.json` plus `<M>@*.symbols.json`, and a unit test holds it.

    **`pathComponents` carries the argument labels.** The second comment says an
    initializer that lost an argument shows as "a changed `declarationFragments` entry,
    on a symbol path that does not move". Measured against a real graph, that is only
    half right: `init(name:text:)` is the path, so dropping a LABEL moves it and reports
    as a removal beside an addition. A changed parameter TYPE keeps the path and reports
    as a changed fragment. Both shapes have a test, and the docstring states the split.

    **Cache size.** The build emits a graph for every module it compiled, MLX included:
    60 MB for one revision. Only the module asked about is kept, so the cache is about
    1.5 MB for each revision. Pruning the five already-extracted revisions took
    `.build/symboldiff` from 300 MB to 8.9 MB, and both corpus reports came back
    byte-identical afterwards.

    **A revision builds against TODAY's dependencies.** `Package.resolved` is not
    tracked, so an old revision resolves the branch tips as they stand now. All four
    corpus revisions build today; one that has drifted may not. This is in the "what
    this does not cover" list.

    ### Verification

    ```
    python3 -m unittest discover -s scripts -p 'test_*.py'   21 tests, 0.04 s, OK
    ruff check --isolated --no-cache --select D1,PLR0915 scripts/   All checks passed
    ruff check --isolated --no-cache --select E,F,W scripts/        All checks passed
    vulture scripts/ --min-confidence 60                            no output
    swift build                                                     Build complete
    swift test   1132 tests in 125 suites passed, plus 83 in 10 suites,
                 2 known issues, both pre-existing (BoundedWaitTests,
                 RealModelHarnessTests). The one build warning, "missing creator
                 for mutated node ... mlx-swift_Cmlx.bundle", is the mlx-swift
                 dependency's and predates this change by 160 runs of shell history.
    ```

    Not committed, not pushed.
  timestamp: 2026-08-30T23:36:13.719069+00:00
- actor: claude-code
  id: 01m1agfzsbbgq418cf6wqt9vg9
  text: |-
    ### implement — changed
    - evidence: 6 files. New: `scripts/symboldiff.py`, `scripts/test_symboldiff.py`, `scripts/README.md`, `Tests/FoundationModelsRouterTests/SymbolDiffScriptTests.swift`. Changed: `README.md` (a "Public API" section pointing at the guidance), `scripts/symbolmap.py` (its header now names `symboldiff.py` as the gate; the command line is untouched, so the ranker's copy stays in step). Corpus: all five breaks report as REMOVED at exit 1 — `ToolMounting`, `OperationEventSink` and `SessionMailbox.makeCompletionToken()` over `6f0b2a8~1..6f0b2a8`; `MergedTranscript` and `OperationEventSegment` over `267994d~1..267994d`. `swift test` 1132 + 83 tests passed; `python3 -m unittest` 21 tests OK; ruff and vulture clean.
    - next: `/review`. One item for the reviewer to weigh: the differ names no consumer, which the card's comments direct and the card's original description does not.
  timestamp: 2026-08-30T23:36:22.571022+00:00
- actor: claude-code
  id: 01m1ahxjfaxbrdpbjjreqztx70
  text: |-
    ### review — findings
    - evidence: 1 finding — scripts/symboldiff.py:178 (`review sha HEAD~1..HEAD`, commit f98daad; counts: 1 finding, 1 confirmed, 1 refuted, 9 attempted)
    - next: validate MODULE against `^[a-zA-Z_][a-zA-Z0-9_]*$` in `read_arguments()`, then run the review again
  timestamp: 2026-08-31T00:01:16.266582+00:00
- actor: claude-code
  id: 01m1ajbmzfnj0w3zkmj5md0nwj
  text: |-
    ### The finding, and the cause behind the one line it names

    The finding, word for word:

    > `scripts/symboldiff.py:178` `code-security/injection` — Path traversal
    > vulnerability: the `module` parameter is concatenated into a glob pattern
    > without validation, allowing attackers to access files outside the intended
    > directory. Validate that module is a valid Swift module identifier (matching
    > `^[a-zA-Z_][a-zA-Z0-9_]*$`) in the `read_arguments()` function before using it
    > in file paths.

    The cited line is one of THREE places the file builds something out of MODULE.
    The whole list, read off the file rather than guessed:

    | site | what MODULE becomes | who reaches it |
    |---|---|---|
    | `graph_paths` | `os.path.join(directory, module + ".symbols.json")` | `keep_only`, `read_surface`, `extract` |
    | `graph_paths` | the glob `module + "@*.symbols.json"` — the cited line | the same three |
    | `build_command` | the `--target` word of the `swift build` command line | `build_symbol_graph`, `extract` |

    So the check stands at each of the three, not at the cited line alone:

    - `MODULE_NAME = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")`, the pattern the
      finding names, as one module constant.
    - `check_module_name(module)` raises `NotAModuleName`, a `SymbolDiffError`, so a
      caller that reaches past the front door gets `EXIT_BROKEN` — a refusal never
      reads as an all-clear.
    - `graph_paths` and `build_command` each call it first. `keep_only`,
      `read_surface` and `extract` reach both through those two, thus one check in
      each leaf covers every path.
    - `read_arguments` validates as the finding directs, and a rejected name exits 2
      with `MODULE is not a Swift module name: <name>` on stderr — the same shape as
      the `PACKAGE_REPO is not a git repository:` message already there.

    The three usage exits in `read_arguments` now share `reject_call(problem="")`,
    which writes the problem and then the usage on stderr and exits 2. A fourth
    hand-written copy of that block was the alternative, and the thread above records
    what happens when two copies of one error path drift apart.

    ### Measured, both streams and both byte counts, for every path

    ```
    no args      stdout 0     stderr 5078  exit 2
    --help       stdout 5078  stderr 0     exit 0
    -h           stdout 5078  stderr 0     exit 0
    2 args       stdout 0     stderr 5078  exit 2
    5 args       stdout 0     stderr 5078  exit 2
    bad repo     stdout 0     stderr 5123  exit 2  "PACKAGE_REPO is not a git repository: /nope"
    ../../etc/passwd  stdout 0  stderr 5131  exit 2  "MODULE is not a Swift module name: ../../etc/passwd"
    Foundation*       stdout 0  stderr 5126  exit 2  "MODULE is not a Swift module name: Foundation*"
    one revision stdout 84080 stderr 0     exit 0
    ```

    The glob case is the one the finding could not have caught by path shape alone:
    `Foundation*` holds no separator, and it still widens the glob past the module
    asked about. The identifier grammar refuses both.

    ### The corpus still catches all five, re-run rather than assumed

    ```
    symboldiff.py FoundationModelsRouter . 6f0b2a8~1 6f0b2a8
        exit 1, removed 10, changed 0, added 0, stdout 2336, stderr 0
        ToolMounting (swift.enum), OperationEventSink (swift.protocol),
        SessionMailbox.makeCompletionToken() (swift.type.method)

    symboldiff.py FoundationModelsRouter . 267994d~1 267994d
        exit 1, removed 20, changed 0, added 0, stdout 2786, stderr 0
        MergedTranscript (swift.enum), MergedTranscript.merged(under:) (swift.type.method),
        OperationEventSegment (swift.struct)
    ```

    The acceptance proof holds at the same ref: at `6f0b2a8` the one-revision form
    still lists `SessionMailbox (swift.class)` with `actor SessionMailbox`, and the
    grep for `SessionMailbox.makeCompletionToken()` on that surface answers 0.

    ### Verification

    ```
    python3 -m unittest discover -s scripts -p 'test_*.py'   25 tests, 0.06 s, OK
    ruff check --isolated --no-cache --select D1,PLR0915 scripts/   All checks passed
    ruff check --isolated --no-cache --select SIM,B,C4 scripts/      3, all pre-existing
                                                                     (symbolmap.py B007)
    vulture scripts/ --min-confidence 60                             no output
    swift build                                                      Build complete
    swift test    1132 tests in 125 suites passed with 2 known issues, plus 83 in
                  10 suites. Both known issues pre-date this change (BoundedWait,
                  RealModelHarness). "the symboldiff unit tests pass" and "the
                  symboldiff unit tests are not silently empty" both passed.
    swift build --package-path IntegrationTests --build-tests        Build complete
    ```

    `ruff --select E,F,W` reports 7 E501 lines, every one of them a line this change
    did not touch (`symbolmap.py:125`, `test_symboldiff.py:142,143,184,189,191,291`).
    An earlier comment records that selection as clean, so the ruff version has moved
    under it. Left alone: no unrelated line was rewritten.

    The one build warning, `missing creator for mutated node ... mlx-swift_Cmlx.bundle`,
    is the mlx-swift dependency's and pre-dates this change.

    Not committed, not pushed.
  timestamp: 2026-08-31T00:08:57.583465+00:00
- actor: claude-code
  id: 01m1ajby3a3dhydah2s1a5p1w8
  text: |-
    ### implement — changed
    - evidence: 2 files — `scripts/symboldiff.py` (added `MODULE_NAME`, `NotAModuleName`, `check_module_name`, `reject_call`; the check now stands in `read_arguments`, `graph_paths` and `build_command`, which are the three sites MODULE reaches a path, a glob or a command word), `scripts/test_symboldiff.py` (a `ModuleNameTests` class: a rejected name over five shapes, an accepted name, a per-site guard test over the four entry points, and the class of the refusal). Written test-first: the new tests failed 5 and errored 5 before the change and pass after. Re-verified by running each and counting both streams — no args stdout 0 / stderr 5078 / exit 2; `--help` stdout 5078 / stderr 0 / exit 0; bad repo names PACKAGE_REPO, exit 2; a bad module name names MODULE, exit 2; the corpus reports removed 10 at exit 1 over `6f0b2a8~1..6f0b2a8` and removed 20 at exit 1 over `267994d~1..267994d`, all five breaks REMOVED. `python3 -m unittest discover -s scripts` 25 tests OK; `swift build` complete; `swift test` 1132 + 83 passed, 2 pre-existing known issues; `swift build --package-path IntegrationTests --build-tests` complete.
    - next: `/review`
  timestamp: 2026-08-31T00:09:06.922487+00:00
position_column: doing
position_ordinal: '80'
title: Check consumers before a symbol goes internal
---
## What

Five public symbols of this package were made internal while a package outside it
still named them. Each one broke that package, and each was found by the consumer
after the fact, not by this package before the change:

| symbol | demoted by | found |
|---|---|---|
| `ToolMounting` | 6f0b2a8 | the consumer's CI |
| `OperationEventSink` | 6f0b2a8 | the consumer's CI |
| `SessionMailbox.makeCompletionToken()` | 6f0b2a8 | a probe here, before the push |
| `MergedTranscript` | 267994d | the consumer |
| `OperationEventSegment` | 267994d | the consumer |

Two rows of that table were corrected on 2026-08-30 by reading each ref with
`git grep`, rather than from memory: `makeCompletionToken()` went at 6f0b2a8 and
not 267994d, and `OperationEventSegment` went at 267994d and not "before
267994d". The four revisions are consecutive.

Four are repaired: ^zgzyhsj, ^cdrxcyc, ^kra1zs6, and ^qynzptr covers the fifth.

A demotion card here cannot see that a package outside this one names the symbol.
Nothing measures it, thus each demotion is a guess.

## What to do

Build a symbol-graph differ, `scripts/symboldiff.py`, and make it the step a
demotion card runs before it changes an access level. The comments on this card
carry the specification; they overrule the paragraphs the card was opened with.

`scripts/symbolmap.py` stays as reference material and is NOT the gate. It matches
type names only, so four of the five breaks above are invisible to it.

## Acceptance Criteria
- [x] A documented command reports every symbol of this package that a named consumer
      package uses, with the access level of each. — `symbolmap.py`, documented in
      `scripts/README.md`. The differ names no consumer, which the comments direct.
- [x] The report covers members, not only type names. Proved: read at `6f0b2a8`,
      `symboldiff.py` reports `SessionMailbox.makeCompletionToken()` as REMOVED
      while the one-revision form still lists `actor SessionMailbox` as public.
- [x] The command names the consumer tree as an argument. Do not fix the path in the
      file. — `symbolmap.py` takes `CONSUMER_REPO` as a required argument with no
      default; `symboldiff.py` takes MODULE, PACKAGE_REPO and one or two revisions,
      and hardcodes none of them.
- [x] The output separates a symbol the consumer names and this package publishes
      from a symbol the consumer names and this package does not. — `symbolmap.py`'s
      three sections: BREAKS WAITING, AMBIGUOUS, SAFE.
- [x] Write in the documentation what the check does not cover. — the "WHAT THIS
      DOES NOT COVER" block of `symboldiff.py --help`, and `scripts/README.md`.

## Beyond the original criteria, from the comments
- [x] Extraction is the SwiftPM route, not a hand-built `-I` list.
- [x] The surface is the SUM of `<M>.symbols.json` and every `<M>@*.symbols.json`,
      and a neighbouring module whose name shares the prefix is never read.
- [x] It diffs two revisions of ONE package with no consumer checked out.
- [x] Three exit states, told apart: 1 removed, 3 changed fragment, 0 added and
      reported. Beside them: 2 a bad call, 4 could not measure.
- [x] The documentation LEADS with "what IS public", and states the reason — a
      requirement inside a `public protocol` carries no `public` keyword.

## Tests
- [x] Run the command against a ref before a known demotion. It reports the symbol.
- [x] Run it against the ref after. It reports the break. All five breaks report
      as REMOVED, at exit 1, over the two pairs `6f0b2a8~1..6f0b2a8` and
      `267994d~1..267994d`.
- [x] Add the command to the guidance a demotion card follows. — `scripts/README.md`,
      linked from `README.md`, and named in the header of `symbolmap.py`.
- [x] `scripts/test_symboldiff.py` holds the pure logic hermetically, and
      `SymbolDiffScriptTests.swift` runs it from the unit target CI runs.

## Note

The consumer session made this offer, and said plainly that the fault was not
one-sided: it told us `SessionMailbox` was safe from memory, and it was not. The
lesson both sides drew is that neither side must state a usage claim without running
something. A check that lives here, and that this package runs for itself, is what
that means in practice. #router #api #tooling

## Review Findings (2026-08-30 18:40)

> Scope: `review sha HEAD~1..HEAD` — reviewed the diffs only — lines this change added or modified. 4 file(s) reviewed, 6 not reviewed.

> 4 file(s) not reviewed — excluded by an ignore rule:
> - `.kanban/ (from .reviewignore)` — 4 file(s)

> 2 file(s) not reviewed — no validator matched:
> - `README.md` — no validator matches this file
> - `scripts/README.md` — no validator matches this file

- [x] `scripts/symboldiff.py:178` `code-security/injection` — Path traversal vulnerability: the `module` parameter is concatenated into a glob pattern without validation, allowing attackers to access files outside the intended directory. Validate that module is a valid Swift module identifier (matching `^[a-zA-Z_][a-zA-Z0-9_]*$`) in the `read_arguments()` function before using it in file paths.
