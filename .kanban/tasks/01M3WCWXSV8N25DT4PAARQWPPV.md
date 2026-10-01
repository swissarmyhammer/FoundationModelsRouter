---
assignees:
- claude-code
position_column: todo
position_ordinal: '8280'
title: Tracing tests fail with FoundationModelsExtras 50fd4a5 (span error recording changed)
---
## Problem

`swift test` fails 6 expectations in 3 suites when the package resolves FoundationModelsExtras `main` at 50fd4a5. The failures exist without any local change (checked with `git stash` on 2026-10-01, during ^ez2g5gw).

Failing tests:

- `ResolveTracingTests`: "a resolve that fits nothing records the failure on its span and opens no load span" (`span.errors.count == 1`), and "a loader failure is recorded on the load span that raised it and on the resolve span" (`resolveSpan.errors.count == 1`, `loadSpans[0].errors.count == 1`).
- `ToolTracingTests`: "a tool call that throws keeps its span, with the error recorded, while the answer goes on" (`span.errors.count == 1`, two rows).
- `TelemetryContentSafetyTests`: "no span, log record or metric carries prompt, response, tool or embed-input text". The span `FoundationModelsRouter.submission` error carries `RejectedToolCallError(... rawTextPreview: "...SECRET-ARGUMENT-VALUE...")`.

## Cause (to confirm)

Extras commits after 42ca5b5:

- cdfe98d `feat(telemetry)!: make TelemetryCapture read span links, span events, recorded errors, the span status message and log record errors`
- 50fd4a5 `fix(telemetry)!: record only the error type on the span of TracedCall.run, never the error description`

The Router code or tests must follow these breaking changes. The content-safety failure shows that a Router span records the full `RejectedToolCallError` description, which holds the tool arguments.

## Note

The local `Package.resolved` (not tracked) pinned Extras at 3de1179, and the build failed (`MLXModelLoader`, `ModelLoadProgress` not found). `swift package update FoundationModelsExtras` moved it to 50fd4a5.

## Tests

- The 6 expectations above pass with Extras at 50fd4a5 or later.