---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0j40hkm2q11h129msy221ns
  text: |-
    ### Closed by the user, 2026-08-21

    The user closed this card without work.

    The measurement that opened it stays true: on 2026-08-20 the seed `three-facts-support-escalation` cost 15.9 s in the 7-fixture run and 82.4 s in the 24-fixture run, on one day, at identical work — two summarizer calls and 1948 summary bytes in both, under greedy decoding.

    The card is also largely moot now. Task ^k0d30s4 cuts the dataset to seven fixtures and deletes the whole-dataset tier, so no gated tier runs long enough for the fall to accumulate. The fall was measured across a 24-sample run; the surviving tier holds 7 samples and measured 63.3 s.

    If a long run is ever needed again, this card holds the measurement to start from.
  timestamp: 2026-08-21T12:16:27.252357+00:00
position_column: done
position_ordinal: ffde80
title: The eval tiers lose 5x of generation throughput as a run goes on, at identical work
---
Found while task ^5q0vv85 timed the whole-dataset compaction eval tier's own samples.

The two gated runs of 2026-08-20 measured the SAME two seeds under the same subject (`mlx-community/Qwen2.5-3B-Instruct-4bit`), the same prompt (`router-default-v3` with task ^xx02yn6's span-budget trim), the same headroom of 128, and greedy decoding:

| seed | subset run | whole-dataset run | summarizer calls | summary bytes |
|---|---|---|---|---|
| `three-facts-long-project-brief` | 15.9 s as sample 6 of 7 | 56.5 s as sample 18 of 24 | 2 in both | 2103 in both |
| `three-facts-support-escalation` | 15.9 s as sample 7 of 7 | 82.4 s as sample 21 of 24 | 2 in both | 1948 in both |

The call count and the summary bytes are equal in the two runs, and greedy decoding repeats an answer exactly, so the WORK is the same. Only the wall clock changed, by 3.6x and 5.2x.

The whole run shows the same shape. The 24 samples cost 11.0, 5.4, 5.1, 3.8, 4.7, 12.2, 3.2, 4.1, 5.9, 5.1, 4.3, 3.3, 4.2, 6.6, 11.0, 3.9, 3.8, 56.5, 24.3, 23.0, 82.4, 27.6, 11.5 and 44.7 seconds. The last seven samples hold the six dearest. The first seventeen average about 5.9 s; the last seven average about 38.6 s.

## Why it matters

- Every gated tier's time limit is derived from a dearest measured sample. If the rate rises with the position in the run, a longer tier needs a much larger bound for the same work, which is what ^5q0vv85 had to do: the whole-dataset limit went from 7 minutes to 33 for a tier that measures 369.1 s.
- A limit that big states little. The bound is 5.4 times the measurement, and only because the spread inside one run is 26x.
- If the cause is ours (a cache that grows, memory pressure, a leak in the resident container, a KV cache never evicted between samples), it is a product defect that every long session pays, not only an eval.

## What to find out

- Whether the fall is thermal (the box), memory pressure (the process), or state that the runner keeps between samples.
- Whether one sample re-run at position 21 costs 82 s or 16 s. The measurement is cheap: run the whole-dataset tier with the seeds in a different order and see whether the dear samples follow the seeds or the positions.
- Whether `CompactionEvalRealSubjectRunner` holds anything between samples that grows. It keeps one resident container for the whole tier and makes a new session for each sample.

## Acceptance Criteria

- [ ] The cause of the fall is named with a measurement, not a guess
- [ ] If the cause is ours, it is filed as its own defect or corrected
- [ ] If the cause is the machine, the tier limits' doc comments state it, because it is then a property of every gated tier
#compaction #eval #real-model #performance