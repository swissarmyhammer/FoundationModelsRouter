---
assignees:
- claude-code
position_column: todo
position_ordinal: '9680'
title: Make the stall report default off; a session reports stalls only when the host installs an interval
---
## Decision (from the owner, 2026-09-22)

`RoutedSessionActor.defaultGenerationStallReportInterval` (30 s, `Session/GenerationStall.swift:111-117`) is an invented default and must go. A session reports a `GenerationStall` only when the host installs an interval with `setGenerationStallReportInterval(_:)`. With none installed, the watchdog does not run.

## Why

- No reason for 30 s is recorded.
- The report stops nothing; it is a host UI feature. The host that wants it names the cadence. With the default on, an unconfigured session logged one warning every 30 s for 33 minutes on a turn that was working (django__django-13964, 2026-09-21).

## Sites

- `GenerationStall.swift:111-117`: the two constants. `:119-127` the setter (keep). `:191-193` `watchGenerationForStalls`: `guard interval > .zero` already returns for a non-positive interval.
- `RoutedSessionActor.swift:432-`: the stored `generationStallReportInterval` and its initial value.
- Tests that rely on the 30 s default (`GenerationStallTests`, any test that waits for a report without installing an interval).

## Do this

1. Delete the two constants. The stored interval starts at `.zero`, and the doc says "off until the host installs one".
2. `setGenerationStallReportInterval(_:)` stays as the one way to turn it on. A fork inherits its parent's interval, as it inherits the other session settings; check and add if missing.
3. Update the tests: a session with no interval reports nothing after 5 s of silence; a session with `.seconds(1)` reports after 1 s.
4. ^4799jxg (what counts as progress) is separate and stays.

## Acceptance

- `rg 'defaultGenerationStallReportInterval'` finds nothing.
- The tests above pass. All tests pass. #compaction #limits