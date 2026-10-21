---
assignees:
- claude-code
depends_on:
- 01M5F3NPMDDMRR7DZQZBXX4CKM
position_column: todo
position_ordinal: '9480'
title: 'ROUTER-4: The rendered message also names the sender''s agent, title and folder'
---
## Goal
Complete section 10.1 item 2: the block that the model sees for a message from another session names the sender's id, agent, title and folder.

## Spec
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 10.1 item 2
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-4-messages-between-sessions

## Blocked on a spec decision (tag needs-decision)
The session that renders the prompt (`Mail.promptText` in `Session/SessionMessage.swift`) has only the sender ULID from `MailBody.agentMessage(from:content:)`, and it cannot read the directory. Options: (a) a new optional sender-card field on the Extras `MailBody.agentMessage` case (an Extras change, owned by the Extras session); (b) the directory writes a trusted header line before the content when it builds the mail, and the renderer moves it out of the fence. Remove the tag and this section when the spec owner chooses.

## What
- (b) as the default plan: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift` builds the mail content with a header from the sender's `SessionSummary` (agent id and name, title, working folder); `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/SessionMessage.swift` renders the header outside the untrusted fence. A sender cannot forge the header: the directory strips a header-shaped first line from the sender's text.
- (a) instead: bump the Extras pin to the revision with the new field and render it in `Mail.promptText`.

## Subtasks
- [ ] Failing test first: a message from session A (agent `reviewer`, title "Review", folder `/tmp/x`) renders a block with all four facts outside the fence.
- [ ] Build the header (or read the new field) in the send path.
- [ ] Render it in `Mail.promptText`.
- [ ] A sender text that starts with a forged header line renders it inside the fence as untrusted text.

## Acceptance Criteria
- [ ] The rendered block names the sender id, agent, title and folder.
- [ ] A forged header in the message text stays inside the untrusted fence.
- [ ] The existing prompt-text tests still pass.

## Tests
- [ ] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/AgentMessagePromptTextTests.swift` (extend)
- [ ] `swift test --filter AgentMessagePromptText` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #mail #needs-decision