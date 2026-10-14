---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: 'H: awaitAnswer(of:) gives the typed error of a failed answer (mail step 2, part H)'
---
Agents found that a caller who puts a user message with mail(_:) cannot get the typed error of a failed answer (for example LanguageModelError.contextSizeExceeded). Only respond and streamEvents throw it, through the private throwIfFailed.

The decision:
- A new public method on RoutedSession: `func awaitAnswer(of id: MailID) async throws -> SessionAnswer`. It waits for the terminal event of the mail id.
  - answered gives the SessionAnswer.
  - answerFailed throws the original error, the same error that respond(to:) throws today.
  - cancelled throws CancellationError.
  - lost and the close of the session throw what awaitTerminal(of:) throws for them today. Say which.
- respond(to:) and the streamEvents helpers use it, or the same code path. Thus one place maps a terminal to a thrown error.
- Say how long the original error is kept (the ledger bound of 4096), and what a call after that bound gets.
- Fixed-order tests: a context overflow gives the typed error through awaitAnswer(of:); a call after the answer ended still gets it; cancel(id) before delivery throws CancellationError.

Run the full suite one time, commit, and report. Push after the reviewer accepts it. #mail #mail-step-2