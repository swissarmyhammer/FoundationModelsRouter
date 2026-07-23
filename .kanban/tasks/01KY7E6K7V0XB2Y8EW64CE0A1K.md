---
depends_on:
- 01KY7E2TP9DBGFV8RJJJKDAE4B
- 01KY7E3ZQ0HV4C4SHH88213X39
- 01KXTFVEAQCJSE7CXA8RJVRGT9
position_column: todo
position_ordinal: '9980'
title: Compaction demo with tools + CompactionContinuityEvaluation
---
Extends the planned Examples/CompactionDemo (rjvrgt9) with the harness's compaction-focused workload, absorbed at collapse: test-only sample tools (a document-generator emitting configurably large text — the context pressure; a fact-store; echo/failing for unit tests), a tiny TokenBudget forcing live folds, rendering the meter + compaction events + checkpointed transcript. Plus CompactionContinuityEvaluation on Apple's Evaluations framework (extends the 26vp325 evals target): multi-step tasks whose later steps depend on pre-fold facts, sized to be impossible without >=1 fold; mechanical evaluators AnswersCorrect / FoldOccurred / FactsSurvived / BudgetHeld / RecordingComplete; fold counts + tokensBefore/After ride along keyed by resolved model — comparing fold prompts = same Evaluation, differently constructed sessions.