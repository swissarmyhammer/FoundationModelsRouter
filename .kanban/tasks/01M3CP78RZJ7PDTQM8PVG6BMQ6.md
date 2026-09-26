---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m3f41c5c5x680rnqm63sdjar
  text: 'Data from ^cx1type stress (24 processes x 60 repetitions, the ^zr22hpd filter, load 7 to 34), 4 rounds: exit 134 with `_ContiguousArrayStorage deallocated with non-zero retain count 2` in 3, 4, 0 and 4 processes. One round also had 2 processes with exit 139 (SIGSEGV, EXC_BAD_ACCESS in `_swift_release_dealloc`). Crash reports swiftpm-testing-helper-2026-09-26-100246.ips and -100253.ips: the faulting frames are FoundationModels frames and `SessionLanguageModel.Executor.respond(to:model:streamingInto:)`, so it looks like the same use-after-free in another form. Round 1 was at HEAD c75de40 with no change, so this is not from ^cx1type.'
  timestamp: 2026-09-26T15:06:16.620223+00:00
position_column: todo
position_ordinal: 8d80
title: Find the crash in the SDK tool loop under parallel load (_ContiguousArrayStorage deallocated with non-zero retain count 2)
---
## What

Test processes that run a real `LanguageModelSession` tool loop through `LiveBackendContainer` crash under parallel load. The runtime writes this message and aborts (SIGABRT):

`Object ... of class _ContiguousArrayStorage deallocated with non-zero retain count 2 ... resulting in a dangling reference.`

The crashed thread is in FoundationModels code with no symbols, under `completeTaskWithClosure`, then `swift_release_dealloc`. The FoundationModels image offsets are the same in each report: 0x94d8c, 0x95714, 0xde975, 0xdcc4d, 0x376d1. This fault is not the same as the `StubSessionBackend` race that ^9smkhk8 (01M20SJKV6YKW4FAFQH9SMKHK8) fixed. That race was in a test stub. This crash is in the SDK path.

## The fault is at HEAD 158f7bf

I built HEAD 158f7bf in a separate git worktree and ran the stress below. 5 of 12 processes crashed with the same message. Thus the fault was there before ^93kjn94.

## Reproduction

Run 12 `swiftpm-testing-helper` processes at the same time. Each process uses `--repetitions 100`, with this filter:

`FoundationModelsRouterTests\.(RejectedToolCallRetryTests|ToolResultCompactionTests|TurnTokenCeilingTests|SessionEventStreamTests|TurnFinishReasonTests|GenerationCallUsageTests)/`

The result is 4 to 5 crashed processes of 12. The command is in the memory note `stub-backend-producer-race.md`. The tests that were in flight at the crash include `SessionEventStreamTests` ("a turn that throws after the SDK durably recorded a tool call still yields that call's events before the stream fails"), and `TurnTokenCeilingTests` / `TurnFinishReasonTests` tool-calling turns. The two tests of `GenerationQueueTurnTests` (^93kjn94) crash the same way. Each test runs a tool loop through the real SDK.

## Next

- Find out if the race is in our code or in the SDK. Our code includes `MLXFoundationModelsSessionBackend`, the executor wrappers (`QueuedLanguageModel`, `RecordingLanguageModel`), the `transcriptEntries()` reads, and the scripted test models. A thread-sanitizer run (`swift test --sanitize=thread`) of one of these suites is the first step.
- If the race is in the SDK, make a minimal reproduction and record it.

## Acceptance

- The stress above gives 0 crashes of 12 processes over 3 rounds.
- A regression test fails before the fix and passes after it.