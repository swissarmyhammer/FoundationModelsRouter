---
depends_on:
- 01M5HS4WD0VANN9Y288S9DFTDP
position_column: todo
position_ordinal: 9d80
title: 'ROUTER: sub-second ts and sentAt on disk once Extras JSONLFile writes fractional seconds; drop whole-second stamping'
---
## Goal
Transcript `ts` and message `sentAt` keep sub-second precision on disk again, and Router stops stamping `sentAt` at whole seconds.

## Why
^s9dftdp moved transcript.jsonl and messages.jsonl onto Extras `JSONLFile`. Its encoder (`ISO8601JSON.makeEncoder`) writes whole-second ISO 8601, so two events in one second lose their order on disk, and the directory now stamps `sentAt` at whole seconds so that a restored inbox equals what was delivered. The Extras session was asked (2026-10-22) to write fractional seconds.

## What
- Bump Router's pin to the Extras sha with fractional-second dates.
- Remove the whole-second `sentAt` stamping in `RouterSessionDirectory` (added by ^s9dftdp).
- Extras decision (2026-10-22): `ISO8601JSON`, which serves JSONLFile and every other user, writes fractional seconds and reads ONLY that format, with no whole-second fallback. So every Router test and fixture that writes a whole-second date line must switch to fractional seconds. ^s9dftdp rewrote eleven test files and one fixture transcript to whole seconds; find them all, and also any SessionFacts or other JSON that goes through ISO8601JSON.

## Subtasks
- [ ] Failing test first: two transcript events 10 ms apart read back in order with distinct `ts`; a delivered message's `sentAt` survives a restore to the millisecond.
- [ ] Remove the whole-second stamping.

## Acceptance Criteria
- [ ] Sub-second `ts` and `sentAt` survive a write and a read.

## Tests
- [ ] `swift test` passes.

## Workflow
- Use `/tdd`. Blocked until the Extras sha arrives. #recording #cross-repo