---
assignees:
- claude-code
position_column: todo
position_ordinal: 9b80
title: Guard a recording root against a second writer
---
## Problem

Nothing stops two `Router` instances — in one process or in two processes — from appending to the same recording root. `seq` is an in-memory counter per recorder (Sources/FoundationModelsRouter/Recording/Sinks.swift:87), so a second writer restarts the sequence and interleaves its lines into the same files. The total order corrupts silently: no error, no warning, and the corruption is only discovered (if ever) at restore time. The concurrent-writer case is also explicitly untested (noted in the restoration audit).

## Proposed solution

1. Take ownership of a recording root at first write: create a lock marker (a lock file with the owner's process id and a timestamp, or an `flock` on a well-known file — decide per platform behavior on macOS).
2. A second router that opens the same root gets a typed error naming the current owner. Do not silently share, and do not silently steal.
3. Handle the stale lock: an owner process that died leaves a marker behind. Detect staleness (the pid no longer runs) and take over with a logged warning.
4. Release the lock on clean shutdown.
5. Tests: second in-process router on the same root throws; stale-lock takeover succeeds with a warning; clean shutdown releases.

## Acceptance

- Two live routers can never both write one recording root.
- The failure is a typed error at open time, not corruption at restore time.
- A crashed owner does not permanently brick its recording root. #transcript