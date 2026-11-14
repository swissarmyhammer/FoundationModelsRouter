---
assignees:
- claude-code
position_column: done
position_ordinal: ffffffffff9280
title: Name the declared tools in the tool error of a call to an undeclared tool
---
## Problem

Recursive Flint asks for a `shell` tool in nearly every child session of the ACP agent. The tool error said only "The function was not present in the supplied tool definitions. Correct the call and write it again." On flint4 django-13447, regression tester 01M7E4Z172V9J49K8FD729XZME called `shell` two times, then `runCode detectProjects` three times. The repetition stop fired, and the tester gave up with "No test ran".

## Fix

For `undeclared_tool`, the note says `There is no tool "shell".` and names each declared tool (the tool definitions of the leading instructions entry, else the session's tools). Any other reason keeps the parser detail.

The router does not know host idioms such as `tools.shell.execute` in `runCode`. Wording of that kind belongs to the host, in its instructions or skills.

## Test

`RejectedUndeclaredToolNoteTests`.