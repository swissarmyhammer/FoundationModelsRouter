---
position_column: todo
position_ordinal: '80'
title: Per-session recording root + omittable routerId segment
---
## What

**Upstream ask from `FoundationModelsACPAgent`** (its `plan.md` §5, revised 2026-07-28).

That package has moved transcript storage from a shared home root to **project-local**: `<cwd>/.<name>/transcripts/<sessionId>/`. A transcript is project context — what the agent did to a repo belongs with that repo. Two things in Router's recording layout block it.

## 1. The recording root is per-Router, but sessions span projects (blocking)

`Router.recordingsDir` is a stored property set once at `init` (`Sources/FoundationModelsRouter/Router.swift:67`, `:151`, `:164`), and `recordingDirectory(forSessionId:)` derives every session's directory from it (`Sources/FoundationModelsRouter/RoutedLLM.swift:260-266`):

```swift
recordingsBase
    .appendingPathComponent(routerId.description, isDirectory: true)
    .appendingPathComponent(sessionId.description, isDirectory: true)
```

So **one Router writes every session under one root**. But a single ACP agent process serves many concurrent sessions in *different repos* (ACP `session/new(cwd)`), and one resident profile means one Router holding one loaded model — a Router per project is not an option, since the whole point is that the model stays loaded once.

**Ask: let the caller supply a recording root per session** — e.g. `makeSession(recordingRoot:)`, falling back to the Router-level `recordingsDir` when omitted, so existing callers are unaffected.

Note `makeSession` **already takes `workingDirectory:`** (`RoutedLLM.swift:162-170`), so Router could in principle derive the path itself. That is the wrong split: the consuming package owns the *location policy* (its §5 — dotfolder name, project-local vs home vs absolute, the `.gitignore`), and Router owns the *writing*. Handing Router a root keeps that boundary; handing Router a policy does not.

## 2. The `routerId` path segment (wanted, not blocking)

`routerId` is a fresh ULID per process run, so the segment groups recordings by **process lifetime** — an implementation detail nobody browses by. The meaningful noun for the consumer is the root ACP session: `sessionId` is stable across `session/resume` and is what `session/list` enumerates.

With a per-session root, the segment also becomes actively harmful — the layout would read `<cwd>/.<name>/transcripts/<routerId>/<sessionId>/`, reintroducing exactly the "pile of opaque ULID directories in every repo" that the consumer's earlier design was trying to avoid.

**Ask: make the `routerId` segment omittable**, and record the routerId as **metadata inside the session directory** instead — it is provenance, worth keeping, but it is not structure. Appears in three places: `RoutedLLM.swift:266`, `RoutedLLM.swift:418`, `SessionTreeRestoration.swift:215`.

A routerId may correspond 1-1 with a run of the agent; that is fine and does not make it a good directory level.

## Constraint

Restoration must keep working. `SessionTreeRestoration` reconstructs from the same nesting, so whatever shape is chosen has to round-trip: write with a per-session root and no routerId segment, then restore from it. Existing recordings in the old layout should keep restoring — either by detecting the layout or by leaving the old default in place for callers that do not opt in.

## Acceptance Criteria

- [ ] A caller can specify a recording root per session; omitting it preserves today's behavior exactly.
- [ ] Two sessions from the **same** Router can write to two **different** roots.
- [ ] The `routerId` path segment can be omitted, with the routerId preserved as metadata in the session directory.
- [ ] `SessionTreeRestoration` round-trips both the new flat layout and the existing nested one.
- [ ] No change required of callers that do not opt in.

## Tests

- [ ] Two concurrent sessions on one Router, given different roots, write to those roots and neither leaks into the other.
- [ ] A session written with no routerId segment restores correctly, and its routerId is still readable from metadata.
- [ ] An existing nested-layout recording still restores after the change.
- [ ] Omitting the new parameter reproduces the current directory layout byte-for-byte.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.