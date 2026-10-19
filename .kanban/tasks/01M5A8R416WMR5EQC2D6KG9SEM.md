---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffff9380
title: 'SessionOutbox adopts CatalogNoticeSink: a catalog notice is one queued mail that rides the next submission'
---
Request from foundationmodelsacpagent-a5. The Extras board (e6b2bf9) casts the session sink to CatalogNoticeSink. The Router outbox is not one, so every notice is dropped.

- `post(catalogNotice:)` puts ONE mail: `MailBody.catalogChange(notice)`, sender `.catalog(kind)`. It renders as `notice.text` and is recorded in the transcript (mailQueued, then delivered with the prompt).
- It is neither user-type mail nor run mail. It never wakes the pump, never starts an answer, and holds no WorkKind.mail lease. It rides the next submission (a first submission or a continuation), the same as held run mail.
- Change the `!isRunMail` sites that mean "user-type" to `isUserMail`. A mail-only pause also holds the notices of its batch.
- Each live session gets its own copy, child sessions too.

Tests first:
- a notice alone starts no answer and leaves the session at no-work (the acp-agent `run` hang case)
- the next prompt carries the text
- a notice that arrives after the last prompt still gives a no-work idle
- a child session gets its own copy

Depends on Extras adding MailBody.catalogChange. Coordinated with foundationmodelsextras-8f.