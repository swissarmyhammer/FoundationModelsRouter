---
sessionId: 01M3CWVB5NFSC7HFT40W63E4TX
cwd: /fixture-work/
updatedAt: 2026-09-25T18:22:10.101Z
additionalDirectories: []
tags: []
slot: standard
model: org/std-a
context: 1000
recordingLevel: full
routerId: 01M3CWVB5J9PBZCS85Z2TW6Y59
compactionCount: 0
profile:
  definitionName: coding
  standard: org/std-a
  flash: org/flash-a
  embedding: org/emb-a
  context: 1000
configuration:
  workingDirectory: file:///fixture-work/
  toolNames: []
  compactionPrompt:
    name: router-default-v7
    text: |-
      Summarize the conversation above. Whoever continues has no other memory of it.
      Start with a line "Values:" that gives each code, name, path and number the user asked to keep or the next step needs, copied exactly.
      Then write a short summary of the few points that matter to go on:
      - what the user wants;
      - what is decided, and what must not be done;
      - what is done, and what comes next.

      Leave out small talk, and finished work that does not matter next. Use plain sentences or short bullets.
  repetitionDetection:
    isEnabled: true
    windowTokens: 2048
    minimumLineLength: 20
    recoveriesPerTurn: 2
schemaVersion: 2
---
