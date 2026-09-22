---
assignees:
- claude-code
position_column: todo
position_ordinal: '9780'
title: RecordedTranscriptCompactionIntegrationTests throws a chat-template error before the summarizer call
---
## What happens

On 2026-09-22, during ^35j2zfg, `swift test --package-path IntegrationTests --filter RecordedTranscriptCompactionIntegrationTests` failed. The test "one compaction of the recorded transcript against a real model" recorded this error at RecordedTranscriptCompactionIntegrationTests.swift:259:

`TemplateException(message: "Cannot put tools in the first user message when there's no first user message!")`

The run took 2.0 s, and 1.9 s of it was the model load (Llama-3.2-1B-Instruct-4bit). The error comes before the summarizer writes output. The output ceiling of ^35j2zfg thus does not cause it.

## Do this

1. Find the call that renders the chat template with the recorded tools and no user message. Candidates: the token count of the live context in `Summarization.plan`, or the summarizer call on the blank backend after ^pke18c2.
2. Correct the cause. Do not change the fixture to hide it.
3. Run the suite again and record the result on this card.

#compaction