---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: 'QueueDepthProbe doc: the depth increment comes in the enqueue step (after the Extras fix)'
---
Source: request of the coordinating session (swissarmyhammer-96), 2026-10-17.

Extras will push a fix (local e87e88f, in the push of Extras card ^7n7bnkz). The GenerationQueue depth increment now comes under the enqueue lock, after the job is in the worker input, and not in `Job.init`. A job that the queue refuses before the enqueue gets no depth change. There is no public API change. Thus `QueueDepthProbe` signals a little later, in the step that queues the job.

Condition: start only after the coordinating session says that Extras pushed this fix. Do not change the order of the `t1-followup` chain for this card. Put the change in the next batch after that message.

- [ ] Change the doc at Tests/FoundationModelsRouterTests/Helpers/QueueDepthProbe.swift:6-11 to say: "the queue records the increment in the step that puts the job in its input, under the enqueue lock".
- [ ] With the new Extras head, check that these 4 suites give the same results: ResolveCancellationTests, ExtrasPoolResolveTests, PoolEntryQueueTests, SummarizerSubmissionTests. If CI on the new Extras head fails in one of them, tell the coordinating session.
- [ ] Run the full suite one time.