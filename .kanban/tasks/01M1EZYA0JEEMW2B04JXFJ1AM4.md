---
assignees:
- claude-code
position_column: todo
position_ordinal: '80'
title: Decide which other gated suites must pin the chat template's date
---
## What

Task ^f0k3aah gave every caller a way to stop a chat template reading the
clock: `PinnedDateTokenizerLoader`, reached through
`RealModelContainer.load(ref:context:samplingMode:chatTemplateDate:)`.

Only `CompactionSmokeIntegrationTests` passes a date. The parameter defaults to
`nil`, so the other gated suites still put today's date into every prompt.

## Why it matters

The defect ^f0k3aah fixed was not special to compaction. The Llama family
stamps `Today Date: <today>` into every system header, and `strftime_now` reads
the clock. Any suite that asserts on the exact text a model wrote is a new
sample on every calendar day. ^erv2vxz measured that costing two whole working
days before anyone found the cause.

## What to do

Read each gated suite in `IntegrationTests/`. For each one, answer one
question: does a red run mean the code changed, or can it mean the date
changed?

- A suite that asserts on exact generated text, or on numbers derived from it,
  must pin the date.
- A suite that asserts only that something ran, or that a value is in a wide
  range, does not need it.

Pin the ones that need it, one at a time, and record the fold numbers each one
reports before and after. The numbers WILL move, because the prompt moves.

## Acceptance Criteria
- [ ] Every gated suite is listed, with the answer to the question above.
- [ ] Each suite that needs the pin has it.
- [ ] Each pinned suite's new numbers are recorded in its own doc comment.

## Tests
- [ ] `swift test --package-path IntegrationTests` green.
- [ ] Each pinned suite green under two different `TZ` dates.
#router #real-model #ci #test-reproducibility