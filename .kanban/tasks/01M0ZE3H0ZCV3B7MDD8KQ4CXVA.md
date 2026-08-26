---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zejfmvhdecqkgafr95hekf
  text: |-
    ### this card cannot be worked in this repository

    The board is READY for this card, but no agent can implement it here. The code it asks to change is not in `FoundationModelsRouter` and not in `FoundationModelsMultitool`. The `review` engine is served by the `sah` MCP server, which is the SwissArmyHammer tool itself, a separate product with its own repository.

    So an agent that picks this card up will search this workspace, find nothing to edit, and either stall or invent something. Read this first.

    **What to do with it.** One of:
    1. Move it to the SwissArmyHammer repository's own board, and delete it here.
    2. Keep it here only as a record of a limit this project has to work around, and take it off the ready queue so `/finish` does not pick it.

    **Choose 2 if the answer is a workaround rather than a fix.** The workaround is already in use and is written on ^dmttqz1: ask a session whose workspace is the other repository to run the engine and send the findings back. It works. It cost this batch about 35 minutes of waiting on a single card, and the findings must be copied onto a board in the other repository by hand.

    **The evidence, for whoever takes it to the other repository.** A session rooted in `FoundationModelsRouter` calling the engine on a path under `../FoundationModelsMultitool` is refused with "path escapes the repository root". Observed 2026-08-26 while ^dmttqz1 was driven from a Router session.

    The third option on the card — make the refusal message name the session to run it from — is the cheapest real improvement, because it turns a dead end into an instruction.

    I have not changed the card's column or its tags, because moving a card between products is a decision for a person.
  timestamp: 2026-08-26T16:31:08.443230+00:00
- actor: claude-code
  id: 01m101txsswtqv4tkwnb2wr0rb
  text: |
    ### closed here, filed upstream as `^eknn45e`

    **What the bug is, stated plainly.** The `review` engine binds to the repository root of the calling session and rejects any path outside it. Exact reproduction, run from this repository:

        review file ../FoundationModelsMultitool/Sources/FoundationModelsMultitool/MultiTool.swift

        Error: review pipeline failed: Validator 'scope' error: path
        '../FoundationModelsMultitool/Sources/FoundationModelsMultitool/MultiTool.swift'
        escapes the repository root

    An absolute path fails identically. `cwd`, `root`, `workspace` and `path` do not move the root.

    **Why it matters here.** `FoundationModelsRouter` declares the protocol and `FoundationModelsMultitool` conforms to it. One change lands in both, and `swift package edit` links them into one build. The change is a single unit of work, but a session in this repository can review only half of it.

    **The workaround, and its cost.** A second session opened in the sibling checkout runs the review and reports the counts back over the cross-session channel. It works — it is what closed `^dmttqz1` and `^f1j3ymz` — but it needs a person to open that session, and it puts the review result in a different context from the change that caused it.

    **The sharper failure behind it, which is the reason this is worth fixing.** A cross-repository review must be scoped by hand, and a diff scope over a commit that renames a file silently declines whole rule families while still reporting `findings: 0`. On `^dmttqz1`, `function-length-swift`, `magic-numbers-swift` and `missing-docs-swift` each reported "found no file at Sources/FoundationModelsMultitool/MultiTool+Detachment.swift" because a later commit had renamed it to `MultiTool+Background.swift`. The run returned zero findings anyway. A person reading the declined-rule list is the only reason that gap was caught, and a second pass at the new path is what closed it.

    **Where it now lives.** `^eknn45e` on the SwissArmyHammer board, "review: cannot review a sibling checkout — path escapes the repository root". It carries the reproduction, the rename trap, and an acceptance criterion that the engine either supports an explicit root or says which alternative is supported rather than reading as a path error.

    Closed here on the user's instruction: the defect belongs to the engine's own repository, and this board cannot fix it.

    - next: none. Card closes.
  timestamp: 2026-08-26T22:07:48.025522+00:00
position_column: done
position_ordinal: ffff8980
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