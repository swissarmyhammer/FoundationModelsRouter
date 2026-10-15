---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m50qryd7ttgmwpwpngkt9g08
  text: |-
    Research (implement):
    - Extras moved to main 6a12b21 in the root and in IntegrationTests (both checkouts at 6a12b21; only this repo's sourcekit-lsp, pid 79950, was stopped).
    - Extras: `ElicitationRequestedSchema.invalidAnswerReasonPrefix = "the answer is not valid: "` and `validationFailure(of:) -> String?` (OperationEvents/ElicitationValidation.swift). A schema with no properties is a free answer: only `required` is checked.
    - Extras ToolContext.elicit validates AFTER `runPlane.awaitAnswer` returns (private static `checked(_:to:)`): guard `request.mode == .form`, `answer.action == .accept`, `requestedSchema` not nil, failure not nil; then it gives `.decline(reason: invalidAnswerReasonPrefix + failure)`. Thus the run plane gets the original response, and Extras makes its own decline. Router keeps sending the original response to the run plane; only the `elicitationAnswer` mail changes.
    - Router: `AskedQuestions.noteAsked(_:runToken:)` records each question from the journal (`noteQuestionAsked`), after `SessionOutbox.post(event:)` awaits the journal write. A test that forwards the elicit post to `session.outbox` (after a first submission attaches the journal) thus has the question in the record when the post returns.
    - A question that is not in the record (for example asked before a restore, or a ToolContext with a sink that does not reach the journal) keeps today's mail.
  timestamp: 2026-10-15T21:33:59.079052+00:00
- actor: claude-code
  id: 01m50r9wqf6fa1jkjka5kvyd0f
  text: |-
    ### implement — changed
    - evidence: files: Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift (Question.requestedSchema for form questions; AskedQuestions.mailedResponse(answering:with:)), Sources/FoundationModelsRouter/Session/RoutedSessionActorQueueing.swift (respond reads the mailed response before the run plane call, mails it; the run plane still gets the original response, so Extras ToolContext.elicit does its own decline), Sources/FoundationModelsRouter/Session/RoutedSession.swift (doc), new Tests/FoundationModelsRouterTests/ElicitationAnswerValidationTests.swift (4 tests).
    - red: before the production change, the 2 decline tests failed on assertions (mail held `accept: {}` and `accept: {"name":"Ada","nickname":"A"}`, no decline text); the valid and free-answer tests passed (they guard behavior that must not change).
    - green: suite 4/4 passed. `swift build --build-tests` after touch: no Router warnings. Full suite: "Test run with 1744 tests in 211 suites passed after 6.360 seconds with 1 known issue." (the known issue is the existing RealModelHarness withKnownIssue), plus "26 tests in 14 suites passed" and "19 tests in 3 suites passed". IntegrationTests `swift build --build-tests`: Build complete (only the mlx dependency warning).
    - Extras at 6a12b21 in both checkouts.
    - The last subtask (push) stays open: the dispatching agent said do not commit or push.
    - next: /review
  timestamp: 2026-10-15T21:43:14.415924+00:00
position_column: doing
position_ordinal: '80'
title: Mail the same decline as the run gets for an accepted form answer that breaks the schema
---
Do not start this task until the reviewer gives the Extras head of task 19.

Extras task 19 adds `ElicitationRequestedSchema.validationFailure(of:) -> String?` and `invalidAnswerReasonPrefix`. ToolContext.elicit gives the run `.decline(reason: invalidAnswerReasonPrefix + failure)` for an accepted form answer that breaks the schema.

Today `respond(elicitationId:response:)` also posts the answer as `elicitationAnswer` mail, with the content that the client sent. For an accepted form answer that breaks the schema, the model then sees the invalid content while the run sees a decline.

Where Router has the schema: the journal records each question from its `elicitationRequested` event in `AskedQuestions.noteAsked(_:runToken:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift, called near line 444). The `ElicitationRequest` there carries `requestedSchema` (form mode). Today the record keeps only the state and the run token. This task keeps the schema of each open form question there too.

- [x] Keep the requested schema of each open form question in `AskedQuestions`.
- [x] In `respond(elicitationId:response:)`, for an accepted form answer, run the same validator (`validationFailure(of:)`). When it gives a failure, the `elicitationAnswer` mail carries `.decline(reason: invalidAnswerReasonPrefix + failure)` and not the invalid content. Thus the model and the run see the same answer.
- [x] A valid answer, a decline, a cancel and a URL answer do not change.
- [x] Fixed-order test: an invalid accepted answer gives the run and the mail the same decline with the same reason; a valid answer mails its content as before.
- [ ] One full run. IntegrationTests build. Push when green. #elicitation-phase-3