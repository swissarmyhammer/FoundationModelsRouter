# Scripts

Two scripts read this package's API surface. `symboldiff.py` is the one to
trust. `symbolmap.py` is reference material.

## First: what IS public

```sh
python3 scripts/symboldiff.py FoundationModelsRouter . HEAD
```

That is the question to ask first, and the reason is the language. In Swift the
access level is not always written on the declaration line. A requirement inside
a `public protocol` carries no `public` keyword and is public anyway:

```swift
public protocol RoutedSession: Actor {
    @discardableResult
    func respond(elicitationId: String, response: ElicitationResponse) async
        -> ElicitationAnswerDelivery
}
```

Two sessions read that shape and reported public API as internal. A keyword
search agrees with them and is wrong. The symbol graph carries the access level
the compiler computed, so it answers correctly. Measured at HEAD: the command
above lists `RoutedSession.respond(elicitationId:response:)`, and
`Sources/FoundationModelsRouter/Session/RoutedSession.swift` spells that line
with no `public` keyword.

**The failure this prevents is a confident wrong answer, not a missing one.**
Never state what this package publishes from memory or from a text search. Run
the command.

## Then: what a change did to the surface

```sh
python3 scripts/symboldiff.py FoundationModelsRouter . <BEFORE_REV> <AFTER_REV>
```

It compares two revisions of ONE package and needs no consumer checked out.
"Did my public API change?" is the question that catches a changed signature;
"does anyone name this?" is not.

| exit | meaning | what to do |
|---|---|---|
| 0 | clean, or additions only | an addition is where a release note comes from |
| 1 | a symbol was REMOVED | stop: it breaks a consumer today |
| 2 | a bad call | nothing was measured |
| 3 | a declaration FRAGMENT CHANGED | warn: it breaks a consumer that uses what changed |
| 4 | the script could not measure | never read this as clean |

A removal beside a change reports the removal.

## What a demotion card must run

A card that narrows an access level — `public` to `package`, `package` to
`internal`, or any other narrowing — runs this before it lands the change:

```sh
git stash            # or commit the change first
python3 scripts/symboldiff.py FoundationModelsRouter . <BASE_REV> <YOUR_REV>
```

Read the REMOVED section. Each row there is a symbol a package outside this one
can no longer reach. Record the rows on the card, with the decision for each: it
stays public, or the consumer is told. A demotion with no such run on its card is
a guess.

Five real breaks came from guessing, and the differ was measured against all
five. Every one of them reports:

| symbol | demoted at | how it reports |
|---|---|---|
| `ToolMounting` | `6f0b2a8` | REMOVED, exit 1 |
| `OperationEventSink` | `6f0b2a8` | REMOVED, exit 1 |
| `SessionMailbox.makeCompletionToken()` | `6f0b2a8` | REMOVED, exit 1, while the actor stayed public |
| `MergedTranscript` | `267994d` | REMOVED, exit 1 |
| `OperationEventSegment` | `267994d` | REMOVED, exit 1 |

Four of the five are MEMBERS of types that stayed public, so a check that reads
type names alone passes four of them while measuring nothing. That is why
`symbolmap.py` is not the gate.

## Cost

Each revision is built once, and the symbol graph of that commit is cached under
`.build/symboldiff/<commit>/`. A commit is immutable, thus the cache never goes
stale. Measured on an M-series Mac with a warm SwiftPM cache: about 50 seconds
for each revision it has not seen, and under a second for one it has.

## What neither script covers

`symboldiff.py` states its whole contract in its own `--help`, including what it
does not cover. Read it. In short: the public surface only, one module of one
package, nothing about behaviour, and nothing about who calls what.

## symbolmap.py — reference, not a gate

```sh
python3 scripts/symbolmap.py [PROVIDER_REPO] CONSUMER_REPO [REV] [SOURCES_SUBPATH]
```

It reads each type-level declaration of a provider at a revision and searches a
named consumer tree for the name. It matches TYPE NAMES ONLY, so a member of a
public type that goes internal is invisible to it — four of the five breaks
above included. Use it to see which names a consumer mentions at all. Do not use
it to decide whether a demotion is safe.

`FoundationModelsRanker` holds a copy of `symbolmap.py` that takes the same
command line. Keep the two the same.
