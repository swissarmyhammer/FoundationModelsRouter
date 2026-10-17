---
assignees:
- claude-code
depends_on:
- 01M5476D8Y29HMWH8S31B1ZMQ8
position_column: todo
position_ordinal: '9280'
title: 'c4 Audit partial closes: each root and fork session that a test makes closes, also on a throw'
---
Source: decision of the coordinating session on ^5xy53sw, group 4 (c).

Some tests close the root session but not a fork, or close a session on the success path only. Rule T1: a fixture closes also when the test body throws.

- [ ] Find each test that makes more than one session (a root and one or more forks, or more than one root), and check that each session closes, also when the body throws.
- [ ] Correct each test that misses a close. Use the shared teardown helpers (for example `SessionFixtureLifecycle.close(_:opening:)`) in a `defer`, not a new local copy.
- [ ] Run the full suite one time.

Exception rule: first use an event that already exists (the session closes, the run settles, the feed ends). A hook only in test helpers is fine. Do not change production code only for a test hook; bring such a case to the coordinating session (swissarmyhammer-96) before you change it. No .timeLimit, sleep, poll or retry.

Work in one agent, with no parallel agents on the working tree. Edit files only with the edit tool. Do not run swift format.
#t1-followup