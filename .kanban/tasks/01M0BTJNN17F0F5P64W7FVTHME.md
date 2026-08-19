---
assignees:
- claude-code
position_column: todo
position_ordinal: '9380'
title: The whole-dataset compaction eval limit is derived with 11.6 minutes of room and has never been run
---
`compactionEvalFullDatasetTimeLimitMinutes` is `120`, and no run of that tier has ever measured it. Commit `2525f29` re-derived the figure it stands against from directly timed samples instead of a division, and the derived cost moved from 94 minutes to 108.4. The margin went with it: 26 minutes of room became 11.6.

## Why this now needs a real run

The derivation is honest and the constant says it is derived, but it rests on an assumption the target cannot check without running the tier:

- The rate is 271.0 s, the mean of the six samples `^6ssbakk` timed one by one. Their spread is a factor of 1.8, from 197.4 s to 352.0 s. A mean of six is a thin base for a 24-sample multiply.
- The multiply assumes 24 samples cost about 24 times one sample, because MLX gives the resident container serial access. That reasoning is sound, and it is still reasoning.
- The whole-dataset seeds are not the subset seeds. Nothing says the 24 cost what the 6 cost.

At 9.7% margin, any of those three being slightly optimistic puts the tier over its limit. The failure is expensive to find: the run must reach 120 minutes before it reports.

## The work

- Run the whole-dataset tier once, with `FM_ROUTER_COMPACTION_EVAL_FULL_DATASET` set, and capture the progress trail.
- Record the real duration in `compactionEvalFullDatasetTimeLimitMinutes`'s doc comment in place of the derivation, exactly as that comment already asks. State it as measured, and name the run.
- Set the constant from the measurement plus a stated margin, rather than leaving 120 standing because the derivation happened to fit under it.
- If the tier overruns, that is the finding, and the limit or the tier's size is what changes.

## Acceptance Criteria

- [ ] The whole-dataset tier has been run once end to end and its duration recorded
- [ ] `compactionEvalFullDatasetTimeLimitMinutes`'s doc comment states a measurement, not a derivation
- [ ] The constant's value follows from that measurement and a stated margin

## Related

- `^9cw5g6n` — re-derived the figure and moved the margin to 11.6 minutes. Its criterion 3 was met in substance; this card carries the whole-dataset run that criterion could not reach.
- `^6ssbakk` — the trail that timed the six samples the rate rests on.
- `^23qeprz` — the dispatch shape is unmeasured, which this run would also settle for the whole-dataset tier. #compaction #eval #real-model #test-debt