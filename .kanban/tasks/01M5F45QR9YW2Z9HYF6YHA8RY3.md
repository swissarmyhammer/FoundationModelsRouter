---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5f4a08nvczc1dgxnjk6dd2f
  text: |-
    ### decision — from foundationmodelsmultitool-bc (2026-10-21)
    - The directory writes the header, and Extras adds no new MailBody field. On delivery the content is: the sender (title, agent, folder, or "the user") plus inReplyTo, then the text inside the "untrusted message" fence of session.md §8 (line 579). The transcript copy for the UI still uses _meta.sah.message (ACPA-6).
  timestamp: 2026-10-21T11:42:22.997064+00:00
- actor: claude-code
  id: 01m5j652ea42a4m8cjag37a880
  text: |-
    Research (picked up, moved to doing). Following the recorded decision (option b: the directory writes the header, no Extras change).
    - Producers of `.agentMessage` mail: only `RouterSessionDirectory.mail(id:carrying:from:)` (used by `start`, `deliver`, `startAgent`) and `MailBody.replacingHookPromptText(with:)` in `RoutedSessionActorPromptHooks.swift` (rebuilds the body after a PrePrompt hook). Renderer: only `Mail.promptText` -> `agentMessageText(from:content:)` in `Session/SessionMessage.swift`.
    - Plan: new internal `AgentMessageHeader` (Session/) holding sender id, agent id, agent name, title, folder path, inReplyTo. The directory always writes it as the FIRST line of the content (marker + one-line JSON), built from the sender's live `SessionSummary` (id-only when the sender is not live, e.g. a `startedBy` id with no session). The renderer splits the content at the first line break, accepts the header only when it decodes and names the same sender as the mail body, renders its facts as quoted lines outside the fence, and fences the rest. Because the real header always comes first, a forged header in the sender's text is at line 2+ and stays inside the fence (the subtask/acceptance wording); the card's "strip a header-shaped first line" is not needed, and stripping would contradict "renders it inside the fence as untrusted text".
    - Fact values (title, folder, agent name) are sender-controlled, so each renders quoted with quotes, backslashes, control and line/paragraph separator characters escaped: no value can break a line outside the fence.
    - The PrePrompt hook keeps seeing only the message text: `hookPromptText` drops the header and `replacingHookPromptText` re-attaches it, so a hook can neither see nor drop the trusted header.
    - Not building on session.json/facts.json/sessions.jsonl: the facts come from the live registry summary (`session.facts`), no new reads of recorded files.
    - Fence label stays "message from another agent" (from ^bxx4ckm); the existing prompt-text tests that build raw mail are unchanged; the restore test and `RouterSessionDirectoryMessageTests.aMessageBySessionIdReachesTheTargetAndItsTranscript` need their expected content updated because send now writes the header.
  timestamp: 2026-10-22T16:12:21.834218+00:00
- actor: claude-code
  id: 01m5j6jzdfjqp2s3yc6jqq352z
  text: |-
    Implementation landed (not committed).
    - New `Sources/FoundationModelsRouter/Session/AgentMessageHeader.swift`: `AgentMessageHeader` (sender, agentID, agentName, title, folder, inReplyTo; `init(sender:summary:inReplyTo:)`; `factLines` renders `agent: "…"`, `agent name: "…"`, `title: "…"`, `folder: "…"`, `in reply to: <ulid>`, each text value quoted with `"`/`\` escaped and control, line-separator and paragraph-separator characters written as `\u{hex}`) and `AgentMessageContent` (header line = `[sender facts] ` + one-line JSON, then `\n`, then the text; `init(parsing:from:)` trusts the first line only when it decodes and names the mail-body sender).
    - `RouterSessionDirectory.mail(id:carrying:from:inReplyTo:)` is now a nonisolated instance method that writes the header from the sender's live summary (new `liveSummary(of:)`, which `summary(of:)` reuses); `start`, `deliver` and `startAgent` pass `inReplyTo`.
    - `Mail.promptText` renders the fact lines between the sender line and the notice; the fence wraps only the text.
    - `MailBody.hookPromptText` gives a PrePrompt hook the text without the header; `replacingHookPromptText(with:)` keeps the header.
    - RED seen: the 4 renderer tests and the restore test failed on missing fact lines (stub codec); after the codec, the 2 hook tests failed (hook saw the header line) and the 2 directory tests failed (send wrote no header). All went green after each step.
    - Not done on purpose: the card's What says the directory "strips a header-shaped first line from the sender's text". Because the directory always writes the real header first, a forged header is never line 1 and stays inside the fence, which is what subtask 4 and the acceptance ask; stripping would remove it instead of fencing it.
    - Open for review: the decision comment mentions the "untrusted message" fence of session.md §8 (the `read inbox` result). The prompt block keeps the fence label "message from another agent" that ^bxx4ckm set; no label change was made.
    - The restore test in AgentMessagePromptTextTests now configures its sender (agent, agent name, title, folder) and expects the fact lines; the four raw-mail prompt-text tests are unchanged and pass.
  timestamp: 2026-10-22T16:19:57.487945+00:00
- actor: claude-code
  id: 01m5j6k5mzmajejars356yjar8
  text: |-
    ### implement — changed
    - evidence: 6 files — Sources/FoundationModelsRouter/Session/AgentMessageHeader.swift (new), Sources/FoundationModelsRouter/Session/SessionMessage.swift, Sources/FoundationModelsRouter/Session/RoutedSessionActorPromptHooks.swift, Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift, Tests/FoundationModelsRouterTests/AgentMessagePromptTextTests.swift, Tests/FoundationModelsRouterTests/RouterSessionDirectoryMessageTests.swift. `swift build --build-tests` OK (only the existing SwiftPM "missing creator for mutated node" mlx bundle warning); filtered run 13/13 pass; full `swift test` exit 0 (2124 tests in 260 suites passed with 9 existing known issues, plus 38 and 19 in the other targets).
    - next: /review
  timestamp: 2026-10-22T16:20:03.871235+00:00
- actor: claude-code
  id: 01m5j6t2rxmnsb8085j403ekpy
  text: |-
    ### review — clean
    - evidence: review sha HEAD~1..HEAD (08c2b41b) — 0 findings (attempted 7, confirmed 0, refuted 0, failed 0); 6 files reviewed, 2 .kanban files excluded by .reviewignore
    - next: done
  timestamp: 2026-10-22T16:23:50.301899+00:00
- actor: wballard
  id: 01m5j6tkcjzdajj6acwbjcarqc
  text: |-
    ### finish iteration 1 — clean
    - implement: changed — AgentMessageHeader, renderer, prompt hooks, directory mail header; tests
    - test: green per implementer — swift test 2124 passed, 9 known issues
    - commit: 08c2b41b
    - review: clean — 0 findings; card in done
  timestamp: 2026-10-22T16:24:07.314007+00:00
depends_on:
- 01M5F3NPMDDMRR7DZQZBXX4CKM
position_column: done
position_ordinal: ffffffffb180
title: 'ROUTER-4: The rendered message also names the sender''s agent, title and folder'
---
## Goal
Complete section 10.1 item 2: the block that the model sees for a message from another session names the sender's id, agent, title and folder.

## Spec
- /Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/session.md section 10.1 item 2
- /Users/wballard/github/swissarmyhammer/TestudoApp/features/packages/foundationmodels-router.md#router-4-messages-between-sessions

## What
- (b) as the default plan: `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Directory/RouterSessionDirectory.swift` builds the mail content with a header from the sender's `SessionSummary` (agent id and name, title, working folder); `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Sources/FoundationModelsRouter/Session/SessionMessage.swift` renders the header outside the untrusted fence. A sender cannot forge the header: the directory strips a header-shaped first line from the sender's text.
- (a) instead: bump the Extras pin to the revision with the new field and render it in `Mail.promptText`.

## Subtasks
- [x] Failing test first: a message from session A (agent `reviewer`, title "Review", folder `/tmp/x`) renders a block with all four facts outside the fence.
- [x] Build the header (or read the new field) in the send path.
- [x] Render it in `Mail.promptText`.
- [x] A sender text that starts with a forged header line renders it inside the fence as untrusted text.

## Acceptance Criteria
- [x] The rendered block names the sender id, agent, title and folder.
- [x] A forged header in the message text stays inside the untrusted fence.
- [x] The existing prompt-text tests still pass.

## Tests
- [x] `/Users/wballard/github/swissarmyhammer/FoundationModelsRouter/Tests/FoundationModelsRouterTests/AgentMessagePromptTextTests.swift` (extend)
- [x] `swift test --filter AgentMessagePromptText` passes; the full `swift test` stays green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass. #session #mail