---
assignees:
- claude-code
position_column: todo
position_ordinal: 8b80
title: Review engine cannot review the sibling repository from a Router session
---
## What
The `review` engine binds to the repository root of the session that calls it. A session whose workspace is `FoundationModelsRouter` cannot review a file in `../FoundationModelsMultitool`: the call is refused with "path escapes the repository root".

This is a real cost, not a small trouble. The two repositories are one body of work — the Router gives the `BackgroundTool` contract and the Multitool uses it — so a task very often changes one and must be reviewed in the other. Today the only way is to ask a second Claude session whose workspace is the Multitool to run the engine and to send the findings back. That makes a hand-off, and the hand-off is slow: one such review held a whole `/finish` batch for more than 20 minutes, and the findings must then be copied by hand onto a board in the other repository.

Observed on 2026-08-26 while task ^dmttqz1 was driven from a Router session.

## Acceptance Criteria
- [ ] A session can review a path in a sibling repository, or the refusal states clearly what to do instead.
- [ ] The chosen answer is written down where a reader will find it, with the reason.

## Tests
- [ ] A test proves a review of a path outside the session's repository root. It either gives findings, or it fails with the stated message.

## Notes
Three answers look possible. A person must choose:
1. Let the engine take a repository root as an argument, so a caller names the repository to review.
2. Let a task say which repository it belongs to, and let `/finish` start the correct session.
3. Keep the limit, but make the refusal say "run this from a session whose workspace is X", so the next agent does not have to find that out.

#workflow #tooling