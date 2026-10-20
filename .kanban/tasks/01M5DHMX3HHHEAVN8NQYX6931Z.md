---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m5dj88pgb7yybbmeadj4z0yv
  text: 'Step record: RED RunMailSubmissionTracingTests (2 tests): the mail-cause span had another trace id, no parent and no link; the message span carrying two run mails had no links and no parent. Option B implemented in SessionOutbox.stage, RoutedSessionActorPump (answerParentContext, deliver), RoutedSessionActorSubmissionEvents.beginSubmission (span links), RoutedSessionActor.openAnswerMailSenders. swift build --build-tests clean; swift test 1931 passed, 9 known issues; 26 and 19 in the other targets.'
  timestamp: 2026-10-20T21:07:37.296893+00:00
position_column: review
position_ordinal: '8380'
title: Run-mail-only submission gets a parent span and links to the mail senders' spans
---
From foundationmodelsacpagent-a5, telemetry-16 (django__django-13447, router 4b6bcc9). The root session wakes on the coder agent's mail as FoundationModelsRouter.submission id 4 (cause "mail", 38 s, mail_ids 01M5DF9WFERM1NWMQ1V2JZ74RP, 01M5DG9FKK7712SSAF6J39Q0NE). It is a root span in a new trace with no parent and no link.

Cause: beginSubmission opens the span under ServiceContext.current ?? .topLevel in a Task.detached pump. runAnswer(of:workId:) takes the parent only from batch.userMail.first and callers[...].serviceContext. SessionOutbox.stage(event:as:) records no caller context for run mail, so a batch of only run mail always starts a new root trace.

Needed (acp-agent card ^3p03s3r waits on this):
1. A parent for that submission. Option A: a host-set work context, e.g. RoutedSession.setWorkContext(_ context: ServiceContext?), that runAnswer uses when no caller context is present. Option B: stage(event:as:) saves the poster's ServiceContext.current, and runAnswer falls back to the first delivered mail that has one. The choice of API is ours.
2. A span link from each mail/continuation submission to the span of the sender of each delivered mail.

- [x] Failing test first: a run-mail-only submission is a root span today
- [x] A run-mail-only submission has a parent span
- [x] Each mail/continuation submission links to the sender span of each delivered mail

## Done: option B

SessionOutbox.stage(event:as:) records the poster's ServiceContext.current as the MailCaller of the new run mail (before the put, with no own work). runAnswer takes its parent from the caller of the first user-type mail, else from the first delivered mail that has a sender context. deliver() keeps each sender context in openAnswerMailSenders, and beginSubmission adds one SpanLink for each mail of its mailIds that has one, for first and continuation submissions alike. The user-type mail whose caller is the parent is left out, so a plain message submission gets no link to its own parent. No option A API was needed.

Limit: run mail that a failed submission gives back to the queue (requeue) loses its sender context, because the delivery already took it.