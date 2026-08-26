---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zdz5tz4a15wrs4y4545dsv
  text: |-
    ### verified facts for the correction — read-only survey

    The card was raised because the README names types that no longer exist. The open question was whether the surrounding claim is still true. It is. Only the mechanism sentence and the vocabulary are wrong. Here is the evidence, so the implement step does not invent anything.

    **The three sites** (`README.md`):
    - `:21` "mounts each vended tool under `DetachConfiguration.nativeSessionMount`"
    - `:24` "the same tools cannot detach at all"
    - `:129` "never detachment"

    **What is wrong at `:21`.** Two things. `DetachConfiguration` is now `ToolMount`, and `nativeSessionMount` does not exist. More important, the DIRECTION changed. The session no longer applies a configuration to a tool. The tool declares its own mount, and the session reads that declaration:
    - The Router asks the tool: `ToolMounting.swift:42` — `let mount = (typed as? any BackgroundTool)?.mount ?? configuration`
    - When the mount says background, the Router wraps: `ToolMounting.swift:45` — `return BackgroundToolRunner(...)`
    - The Multitool declares it: `MultiTool+Background.swift` — `extension MultiTool: BackgroundTool { public var mount: ToolMount? { ToolMount(mode: .background, timeout: nil) } }`

    **What is still TRUE and must stay.** A bare `FoundationModels.LanguageModelSession` gives none of this. The wrapping happens only in the Router's mounting path, so a bare session calls `MultiTool.call(arguments:)` directly. The call then runs to completion in band. So the sentences "the snippet blocks, no envelope is written, and `wait` has nothing to join" are correct, and the paragraph's point — the session type is part of the contract — holds.

    **The correction.** Keep the meaning, change the mechanism and the words:
    - The tool declares that it runs in the background, by conforming to `BackgroundTool` and giving a `ToolMount`.
    - A `RoutedSession` reads that declaration when it mounts the tool, and wraps the tool so a slow `runCode` starts a background run and answers at once with a pending envelope. The model collects the result with the mounted `wait` tool.
    - On a bare `LanguageModelSession` nothing reads the declaration, so the same tools run in band: the snippet blocks, no envelope is written, and `wait` has nothing to join.
    - Say "background", never "detach" or "detachment". A background run is in motion; "parked" and "detached" both say the wrong thing.

    Write the new text in ASD-STE100 Simplified Technical English.
  timestamp: 2026-08-26T16:20:35.807641+00:00
position_column: todo
position_ordinal: 8a80
title: 'Multitool: correct the README''s stale mount vocabulary'
---
## What
Found during the vocabulary sweep of card ^dmttqz1. `README.md` in
`../FoundationModelsMultitool` describes an API that Router no longer has.
Router at `cc94cce` holds no `DetachConfiguration` and no `nativeSessionMount`.
The type is `ToolMount`, and a tool declares its own
`var mount: ToolMount?`; `ToolMount.Mode` is `.background` or
`.runToCompletion`.

Three sites:

- [ ] The paragraph that says a `RoutedSession` "mounts each vended tool under
  `DetachConfiguration.nativeSessionMount`". Name the type that exists now.
- [ ] The same paragraph says that on a bare
  `FoundationModels.LanguageModelSession` "the same tools cannot detach at
  all: the snippet blocks, no envelope is written, and `wait` has nothing to
  join". State what is true now, in the background vocabulary. Read the code
  first: do not carry the old sentence over with new words.
- [ ] The direct-mode paragraph says "direct mode takes discovery away, never
  detachment". Use the background word.

## Acceptance Criteria
- [ ] `rg -i 'detach' README.md` finds nothing.
- [ ] Each type and member the README names exists in Router at the pinned
  commit.
- [ ] `swift test` in `../FoundationModelsMultitool` stays green.
  `HardeningTests` reads `README.md`, thus a careless edit can break it.

## Tests
- [ ] No new test. The suite must stay green. #cleanup