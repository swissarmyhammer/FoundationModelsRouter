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
position_column: todo
position_ordinal: '8180'
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
| `SessionMailbox.makeCompletionToken()` | 267994d | a probe here, before the push |
| `MergedTranscript` | 267994d | the consumer |
| `OperationEventSegment` | before 267994d | the consumer |

Four are repaired: ^zgzyhsj, ^cdrxcyc, ^kra1zs6, and ^qynzptr covers the fifth.

A demotion card here cannot see that a package outside this one names the symbol.
Nothing measures it, thus each demotion is a guess.

## What to do

`scripts/symbolmap.py` is in this repository already. The consumer session wrote it
and gave it to us. It reads every type-level declaration of the router at a given
ref, then searches a consumer tree for each name. `ROUTER`, `CONSUMER` and `REV` at
the top are the only values to set.

Make it a step that a demotion card runs before it changes an access level.

## Two limits, which the card must keep in view

1. **It matches type names only.** A member of a public type that goes internal is
   invisible to it. That is exactly the shape of the
   `SessionMailbox.makeCompletionToken()` break: the actor was public, so the script
   would have reported the type as safe while the member was already broken.
2. **It excludes `private` and `fileprivate` declarations.** That is correct, because
   no consumer can reach them, but it says nothing about members either way.

So the script as it stands would have caught 4 of the 5 breaks above, and missed the
one that hid the longest.

## The better version

Read both sides with `swift-symbolgraph-extract -minimum-access-level public`, which
is the tool the recent cards already use to count the public surface. That reads
members, not only type names, so it closes limit 1. A regular expression cannot do
this; it needs real Swift parsing or the symbol graph.

Give the extractor `-I <bin>` as well as `-I <bin>/Modules`, because the module is in
the bin directory itself. A count that is one lower than the baseline is a stale
extract, not a lost symbol.

## Acceptance Criteria
- [ ] A documented command reports every symbol of this package that a named consumer
      package uses, with the access level of each.
- [ ] The report covers members, not only type names. Prove it: the command reports
      `SessionMailbox.makeCompletionToken()` when it is read at a ref where the actor
      is public and the member is internal.
- [ ] The command names the consumer tree as an argument. Do not fix the path in the
      file.
- [ ] The output separates a symbol the consumer names and this package publishes
      from a symbol the consumer names and this package does not.
- [ ] Write in the documentation what the check does not cover.

## Tests
- [ ] Run the command against a ref before a known demotion. It reports the symbol.
- [ ] Run it against the ref after. It reports the break.
- [ ] Add the command to the guidance a demotion card follows.

## Note

The consumer session made this offer, and said plainly that the fault was not
one-sided: it told us `SessionMailbox` was safe from memory, and it was not. The
lesson both sides drew is that neither side must state a usage claim without running
something. A check that lives here, and that this package runs for itself, is what
that means in practice. #router #api #tooling