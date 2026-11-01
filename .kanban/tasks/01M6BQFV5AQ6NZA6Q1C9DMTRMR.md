---
assignees:
- claude-code
position_column: todo
position_ordinal: '8980'
title: Handle the Transcript.Entry data case in 13 exhaustive switches
---
The SDK added a `.data(_)` case to `Transcript.Entry`. 13 switches give the warning "switch must be exhaustive, add missing case '.data(_)'". Files: Sources/FoundationModelsRouter/Compaction/Summarization.swift:226, Compaction/ToolOutputProtection.swift:151, Resolution/TokenizerTokenCounter.swift:104, Session/GenerationStall.swift:51, Session/OperationEventSegment.swift:120, Session/RepeatedPartRemoval.swift:170, Session/RepetitionDetector.swift:66, Session/RoutedSessionActorReasoningStop.swift:44 and :63, and in Tests/FoundationModelsRouterTestSupport: CharacterTokenCounter.swift:41, ToolAnswerScenario.swift:246, TranscriptEntryKinds.swift:40. A cached build can hide these warnings. Decide for each switch what a data entry means (for example: counts as zero text, is kept by compaction, is not a repeat). Earlier fixes: commit 5804622c and 9e78b861 handled the case in two test helpers. Add a test where behavior is new. Zero warnings is the aim.