---
assignees:
- claude-code
position_column: todo
position_ordinal: '8180'
title: Mail the same decline as the run gets for an accepted form answer that breaks the schema
---
Do not start this task until the reviewer gives the Extras head of task 19.

Extras task 19 adds `ElicitationRequestedSchema.validationFailure(of:) -> String?` and `invalidAnswerReasonPrefix`. ToolContext.elicit gives the run `.decline(reason: invalidAnswerReasonPrefix + failure)` for an accepted form answer that breaks the schema.

Today `respond(elicitationId:response:)` also posts the answer as `elicitationAnswer` mail, with the content that the client sent. For an accepted form answer that breaks the schema, the model then sees the invalid content while the run sees a decline.

Where Router has the schema: the journal records each question from its `elicitationRequested` event in `AskedQuestions.noteAsked(_:runToken:)` (Sources/FoundationModelsRouter/Session/RoutedSessionActorWorkEvents.swift, called near line 444). The `ElicitationRequest` there carries `requestedSchema` (form mode). Today the record keeps only the state and the run token. This task keeps the schema of each open form question there too.

- [ ] Keep the requested schema of each open form question in `AskedQuestions`.
- [ ] In `respond(elicitationId:response:)`, for an accepted form answer, run the same validator (`validationFailure(of:)`). When it gives a failure, the `elicitationAnswer` mail carries `.decline(reason: invalidAnswerReasonPrefix + failure)` and not the invalid content. Thus the model and the run see the same answer.
- [ ] A valid answer, a decline, a cancel and a URL answer do not change.
- [ ] Fixed-order test: an invalid accepted answer gives the run and the mail the same decline with the same reason; a valid answer mails its content as before.
- [ ] One full run. IntegrationTests build. Push when green. #elicitation-phase-3