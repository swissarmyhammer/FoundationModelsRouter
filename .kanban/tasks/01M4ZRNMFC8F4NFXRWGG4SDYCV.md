---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffe780
title: Mark the old message names in generation-queue.md as history
---
Extras step 8 removes MessageID, MessageCancellationResult and the other old Mailbox types. generation-queue.md still named them.

- [x] A note at the top of generation-queue.md: the mail design in /Users/wballard/github/swissarmyhammer/mailbox.md replaces the message queue design of that document.
- [x] Each line that named MessageID or MessageCancellationResult now gives the current name (MailID, the signals cancel(_ id: MailID) and cancelAll(), the terminal event cancelled(MailID)) or is marked as history.

Docs only. #mail-step-8