---
assignees:
- claude-code
depends_on:
- 01M0XGRJD4TZTZAFTCSBZEKMFD
- 01M0XGRYMR1GPMY1X52FTDMR58
position_column: todo
position_ordinal: '8680'
title: 'Multitool: declare the background tools'
---
## What
Cross-repo task in `../FoundationModelsMultitool` (sibling checkout). First of three Multitool tasks. Apply the declaration API fixed by Router task ^19c9vv4 — a long-running tool declares `var detachmentMount: DetachConfiguration? { DetachConfiguration(mode: .background, timeout: ...) }`; an undeclared tool is synchronous:

- [ ] `runCode` (`Sources/FoundationModelsMultitool/MultiTool.swift`, `MultiTool+Detachment.swift`) declares background — a snippet can run for hours. Its per-call work bound moves to the timeout-only member that replaced `detachmentClocks(from:)` (`MultiTool+Detachment.swift:98` bounds each call at `configuration.executionTimeLimit`).
- [ ] Shell execute (`Capabilities/Shell/Execute.swift`, `ShellRunner.swift`) declares background. Remove the model-facing `wait` argument from `ExecuteArguments` (`Execute.swift:136-158`) and from the schema and description — it controlled the block window, which no longer exists.
- [ ] `searchTools` (`Discovery/SearchToolsTool.swift`) and the file verbs (`Capabilities/Files/**`) declare nothing — synchronous.
- [ ] Inner `tools.*` calls through `ToolInvoker` stay run-to-completion (`RunBinding.innerCallMount`) — verify, unchanged.

## Acceptance Criteria
- [ ] A test proves `runCode` and `execute` always answer with the pending envelope.
- [ ] A test proves `searchTools` and a file verb answer inline.
- [ ] The rendered `execute` schema has no `wait` argument. A test asserts on the schema.
- [ ] FoundationModelsMultitool builds against the updated Router.

## Tests
- [ ] Update `Tests/FoundationModelsMultitoolTests/ShellExecuteTests.swift`, `MultiToolExecutionTests.swift`, and the capability-registration tests.
- [ ] Run `swift test` in `../FoundationModelsMultitool` — green.

## Workflow
- Use `/tdd` — write failing tests first, then implement to make them pass.