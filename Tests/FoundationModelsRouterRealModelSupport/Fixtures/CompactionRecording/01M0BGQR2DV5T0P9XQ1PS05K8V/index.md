---
sessionId: 01M0BGQR2DV5T0P9XQ1PS05K8V
cwd: /recordings/station-archive/
updatedAt: 2026-08-18T22:44:09.421Z
additionalDirectories: []
tags: []
slot: standard
model: mlx-community/Muse-Glimmer-30B-4bit
context: 8192
instructions: "You are a terse, literal engineering assistant. Answer in one short paragraph. You have two tools, `lookup-alpha` and `lookup-beta`. When the user asks you to look up a step, call the matching tool with that step name and quote the identifier it returns exactly."
recordingLevel: full
routerId: 01M0BGQR2D05BNCF0FB0EPXRR6
compactionCount: 0
configuration:
  instructions: "You are a terse, literal engineering assistant. Answer in one short paragraph. You have two tools, `lookup-alpha` and `lookup-beta`. When the user asks you to look up a step, call the matching tool with that step name and quote the identifier it returns exactly."
  workingDirectory: file:///recordings/station-archive/
  toolNames:
  - lookup-alpha
  - lookup-beta
  compactionPrompt:
    name: router-default-v2
    text: |-
      You are compacting an agent conversation into a continuation summary. The
      summary will REPLACE the older conversation: whoever continues has no other
      memory of it, so anything you omit is lost. Be precise and dense. State only
      facts from the conversation — never invent, never infer beyond it.

      Structure the summary exactly as:

      1. Intent — the user's request(s) and overall goal, in order given.
      2. Stated facts — every concrete fact stated in the conversation, each with
         its value written out: names, identifiers, codes, numbers, locations,
         paths, dates, settings, preferences.
         Record WHAT was stated, never merely THAT something was stated — write
         "the spare toner is in the third-floor supply closet", never "the user
         gave the location of the spare toner".
      3. Constraints & decisions — instructions, preferences, and decisions still
         in force. Preserve safety- or security-relevant instructions VERBATIM
         (files or data to avoid, operations not to perform, secret handling).
      4. Completed — work finished so far, with concrete outcomes.
      5. In progress — what is being worked on right now, and its exact state.
      6. Files & code — every file path touched or discussed, with the symbols,
         commands, and short code fragments that matter. Exact paths and names.
      7. Errors & fixes — problems encountered and how they were (or were not)
         resolved. Keep failed approaches so they are not repeated.
      8. Next steps — the immediate next actions, in order, detailed enough to
         resume without re-deriving them.

      No praise, no padding, no meta-commentary. Omit a section only if truly
      empty. Never replace a stated value with a description of it.
schemaVersion: 2
---
