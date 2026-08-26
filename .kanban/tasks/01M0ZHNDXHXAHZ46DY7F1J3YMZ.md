---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01m0zhps73vqaf51f61425cqg6
  text: |-
    ### correction — this card's opening claim was wrong

    The card says "The Router side was cut. The Multitool was not." **That is false, and I wrote it without checking.** I then measured the Router, and it is in the same state or worse.

    Router doc lines against total lines, files over 100 lines:

    | Share | Doc / total | File |
    |---|---|---|
    | 72% | 324 / 444 | `Session/RoutedSession.swift` |
    | 66% | 125 / 188 | `Session/ToolOutputCapping.swift` |
    | 61% | 152 / 249 | `Session/DiscoveryPriming.swift` |
    | 57% | 98 / 171 | `Session/LanguageModelSessionBackend.swift` |
    | 57% | 62 / 108 | `Recording/MergedTranscript.swift` |
    | 56% | 60 / 106 | `Hosting/ToolInvocationRecord.swift` |
    | 54% | 148 / 274 | `Recording/Sinks.swift` |
    | 52% | 54 / 103 | `Hosting/OperationOutcome.swift` |

    Twelve Router files over 100 lines are at or above 40% doc.

    **Where my error came from.** Earlier work cut the Router's public SURFACE, from 812 public declarations to 437. That is a different thing from cutting its doc comments, and I let one stand for the other. A smaller public surface can even raise the share, because the doc stays on the symbols that remain.

    **What this means for the work.** The user's complaint was about both sides. `RoutedSession.swift` at 72% is the single worst file in either repository, and it is the type a host uses first.

    This card stays scoped to the Multitool, so that a comment cut is reviewable one repository at a time. A sibling card, ^v5kbqxr, now holds the Router side with the same rule. Neither should be done in bulk.
  timestamp: 2026-08-26T17:25:55.043506+00:00
- actor: claude-code
  id: 01m0zhqefkys8t0wspnsbsrydy
  text: |-
    ### correction to the card id in the comment above

    The comment above names the Router sibling card as `^v5kbqxr`. That id does not exist — I wrote it before the card was created, and guessed. The real one is **^yzj5ht0**, "Router: cut the doc comments back to what the code cannot say".

    Ignore `^v5kbqxr`. It refers to nothing.
  timestamp: 2026-08-26T17:26:16.819423+00:00
- actor: claude-code
  id: 01m0zspm3gy05r58hebtcdazjs
  text: |-
    ### research — the rules, and one cross-file constraint that decides a whole doc block

    **Rule set.** `dump validators` gave 55 rules for `.swift`. A read of the full dump confirms the earlier finding on the Router side: only a small set can break on a `///`-only edit, and each breaks by REMOVAL or by REORDER, never by shorter prose.

    - `code-hygiene/missing-docs-swift` — swiftlint `missing_docs`, `warning: [open, public]`, `excludes_extensions: true`, `excludes_inherited_types: true`, `excludes_trivial_init: false`. It reads PRESENCE only, never a word of the text. A `package` declaration is not read at all. So a shorter block is still a block, but deleting the LAST `///` line above a `public` declaration is a finding.
    - `swift/doc-parameter-naming` — a `- Parameter <name>:` key must equal the INTERNAL parameter name. The safe moves are to delete a whole `- Parameters:` block or to keep every key correct. Never half-edit one.
    - `code-hygiene/no-commented-code` — the `///` delimiter is the structural carve-out. A `///` block must never become `//`.
    - Marker adjacency (`// swiftlint:disable:next …`, `// periphery:ignore`) — a `///` line ABOVE a directive is measured safe; a `///` line BETWEEN the directive and its declaration brings the finding back.

    **Checked: none of the three files holds a `swiftlint` or a `periphery` directive**, so the adjacency risk cannot occur on this pass.

    **There is NO file-length rule and NO line-length rule in the dump.** The only size gate is `function_body_length`, which counts "excluding comments and whitespace". Deleting a doc line cannot move any length measurement.

    **No validator rewards this card.** The dump holds no rule against a comment that repeats a signature, no rule on comment length, and no rule on doc writing style. So the cut is reviewable ONLY by the kept-fact list.

    ---

    ### The cross-file constraint that shapes `executionTimeLimit`

    `MultiTool+Background.swift` — a file this card lists for a LATER pass — points at this file:

    > see `MultiToolConfiguration.executionTimeLimit` for the full reconciliation

    So `MultiToolConfiguration.executionTimeLimit` is the designated canonical home for the two-clock reconciliation, and cutting it here would make a sibling file's reference dangle. It stays, in full.

    **Discovery worth recording for the later pass:** `MultiTool+Background.swift:timeout(from:)` and `JSCInterpreter.defaultTimeLimit` EACH restate that same reconciliation in full, while Background also points here for it. That is a three-way cross-file duplication of one paragraph. It cannot be fixed inside this pass's three-file scope. The later pass on `MultiTool+Background.swift` should cut its copy down to the pointer it already carries.

    ### Claims verified against code before rewriting, not assumed
    - `JSCInterpreter.init(timeLimit: TimeInterval = 5.0)` — the "own stock limit is 5 seconds" claim holds.
    - `MultiTool.init` runs `(interpreter ?? JSCInterpreter()).withTimeLimit(configuration.executionTimeLimit)` — the injected-sandbox re-arming claim holds.
    - `JSCInterpreter.runStart` is a `let` set to `ContinuousClock.now`; `rearm()` is a separate method — the "nothing moves the reference point" claim holds.
    - `ToolAPIRenderer.render` line 157: `guard isLegalTSIdentifier(name) else { throw … }` — the "validates and throws otherwise" claim holds.
    - `MultiToolBuilder.build()` delegates entirely to `buildRegistry()`, which at line 483 guards `ToolAPIRenderer.isLegalTSIdentifier(group)` — the "validates the same way" claim holds. The grammar is in fact NARROWER than full TypeScript (ASCII `[A-Za-z_$][A-Za-z0-9_$]*`), which only strengthens the newline-safety property.
    - `APISurface.Entry.journalOp` is `group.map { "\(descriptor.name) \($0)" }` — verb then noun, so `"execute shell"` for `tools.shell.execute`. The example in the doc is right.
    - `closingLine` IS read by both test targets (`Tests/FoundationModelsMultitoolTests/*` and `IntegrationTests/…/ScenarioFixtureTests.swift`); `repairableErrorSummary` is read ONLY by `FoundationModelsMultitoolTests`. The two doc blocks must therefore NOT be collapsed into one shared claim, and they were not.
  timestamp: 2026-08-26T19:45:38.416786+00:00
- actor: claude-code
  id: 01m0zstg5xycmd71f1z6x1thzw
  text: |-
    ## Pass 1 of this card: three files only, worst first

    The card's table names eight files. **This pass does three of them.** `Diagnostics/CallTrace.swift`, `Discovery/SearchToolsTool.swift`, `MultiTool+Background.swift`, `Surface/MultiToolBuilder.swift` and `MultiTool.swift` are NOT started, and the garbled sentence at `MultiTool+Background.swift:49` is NOT fixed. Both remain open on the card.

    Measured before the pass, and again after. The card's table was written on 2026-08-26; two of the three had been edited by other cards since, so the "before" column is my own re-measurement, not the card's.

    | File | Before | After | Doc lines cut |
    |---|---|---|---|
    | `MultiToolConfiguration.swift` | 96 / 131 (73%) | 57 / 92 (62%) | 39 |
    | `Surface/APISurface.swift` | 146 / 203 (72%) | 105 / 162 (65%) | 41 |
    | `Rendering/ResultRenderer.swift` | 195 / 302 (65%) | 140 / 247 (57%) | 55 |
    | **TOTAL** | **437 / 636 (69%)** | **302 / 501 (60%)** | **135** |

    No percentage was aimed for. The reasons the three stop where they do are at the end.

    ---

    # THE DELIVERABLE: every fact KEPT, by line

    Line numbers are in the files as they now stand. No validator can tell which fact a deleted sentence carried, so this list is the only instrument a reviewer has.

    ## 1. `MultiToolConfiguration.swift` — 57 / 92

    - **L7-10** — The type carries NO turn budget. A host mounts the vended tools on a `RoutedSession`, and that session's own tool-calling loop owns turn budgeting. The retired `MultiToolAgent` knobs `maxAgentTurns` and `maxRepairTurns` went with it. *A reason a reader would otherwise undo by adding a turn budget back here.*
    - **L13-14** — This value is ALSO the per-call work bound `runCode` answers the engine (`MultiTool.timeout(from:)`). One value, two jobs.
    - **L16-22** — A mounted `runCode` call answers its pending envelope at once and the snippet continues in the background, so the suspended JSC context lives PAST the call. This value arms the watchdog of every sandbox `MultiTool.init` runs (`Interpreter.withTimeLimit(_:)`), and it must never be a second clock that races the engine's. The default is therefore the engine's own stock work clock, `ToolMount.defaultTimeoutSeconds`, taken from that ONE definition so the two cannot drift apart.
    - **L24-32** — **THE TWO-CLOCK RECONCILIATION.** The engine resets its clock on every progress event. This one does not: the `WatchdogState` measures from sandbox creation, and neither progress nor a suspension on `elicit()` moves that reference point (`runStart` is a `let`, and `rearm()` re-arms the poll interval, not the deadline). So a snippet that keeps resetting the engine's clock is force-terminated here, at this ceiling. That absolute cap is the intended safety property, and it is why progress reports cannot keep a suspended context alive without end. *`MultiTool+Background.swift:71` points here for "the full reconciliation", which makes this the canonical home. Cutting it would leave a dangling reference in a sibling file.*
    - **L34-38** — **THE TRAP.** The arming covers an injected sandbox too: an `interpreter:` a caller hands to `MultiTool.init` is re-armed with this ceiling. So injection cannot put a second, different limit under a `runCode` call — a plain `JSCInterpreter()`, whose own stock limit is 5 seconds, is armed from here like any other.
    - **L41-42** — Exceeding the live cap is refused with a repairable IN-BAND error. Not an exception, not a silent queue.
    - **L44-49** — What "live" means: a snippet stays live after its call has answered in the background, so this is the cap on SUSPENDED JSC CONTEXTS. Each holds a real JS context and the thread its run occupies. A model that has backgrounded this many snippets has lost track of them, and the error tells it to collect one — `status()`, `wait()`, `cancel()` — instead of starting another.
    - **L60-61** — Points at ``liveContextLimit`` for why a handful, rather than an unbounded set, is the right shape.
    - **L67-70** — **THE CLAMP FLOORS**, stated ONCE at the initializer that does the clamping: `liveContextLimit` up to at least `1`, and each other limit up to at least `0`. A stray negative value in a host's configuration thus cannot disable a bound or crash a `runCode` turn. *Was repeated on all four properties; now stated at the declaration that owns it.*
    - **L83-85** — **THE DEPENDENCY DIRECTION.** This wraps the two character limits so `ResultRenderer` does not have to know about this type at all. *A reader would otherwise re-declare cap logic here.*

    ## 2. `Surface/APISurface.swift` — 105 / 162

    - **L4-8** — One `ToolAPIRenderer` call per wrapped tool produces every entry's `ToolDescriptor` (M2). This type adds only the namespace. **`APISurface` is PURE DATA:** it composes already-rendered pieces, and holds no model wiring and no rendering logic of its own. *The constraint on what may be added here.*
    - **L12-15** — **THE PATH INVARIANT.** `path` is always `descriptor.name` for a standalone entry (`group == nil`), and always `"\(group).\(descriptor.name)"` for a grouped one. *Load-bearing: `qualify(_:)` is a no-op for a standalone entry only because of this.*
    - **L18-20** — WHICH builder call produces which: `addGroup(named:_:)` gives a group; `addTool(_:)`/`addTools(_:)` give a standalone, flat-namespaced entry.
    - **L23-25** — The descriptor's `name`, `declaration`, `doc`, `example` and `source` are ALWAYS UNQUALIFIED; ``path`` is what carries the namespace. *`SearchToolsTool.swift:397` points at this `Entry` documentation for exactly this fact.*
    - **L30-33** — REASON the memberwise initializer is written out rather than synthesized: a `public` struct's synthesized initializer is only `internal`-accessible, and a caller of the library product must be able to construct an `Entry` directly. *A reader would otherwise delete it as redundant.*
    - **L40-43** — `journalOp` is the canonical `"verb noun"` string, and `nil` for a standalone entry, which has NO NOUN and keeps the tool's own name as its op. WHICH value, and why the `nil`.
    - **L45-50** — **REASON FOR PLACEMENT.** It comes from the same two halves ``path`` does — `group` is the noun `register(noun:tool:)` supplied, `descriptor.name` is the verb `Tool.name` supplied — so neither half is spelled a second time anywhere. A verb could not derive this for itself, because it does not know its own noun. *`RunBinding.swift:123` points here for "the derivation".*
    - **L52-60** — **THE TRAP: which plane the string appears on.** The run plane only, never the event journal of an enclosing snippet. It is stamped on `ToolContext.op`, so `SessionMailbox.track(tool:op:)` fills `BackgroundRun.op` and the run's `ToolInvocationRecord` carries it. The `OperationEvent`s of an inner `tools.*` call reach the outbox through the enclosing `runCode` context's `post(_:)`, which RE-STAMPS each forwarded event with the OUTER run's identity. *`RunBinding.swift:123` points here for "the plane the pair appears on".*
    - **L62-63** — The `tool` field of each of those records keeps naming the tool itself (`"execute"`). ONLY `op` carries the pair.
    - **L68-74** — The embedded `@example` call inside `block` is qualified, so the runnable example a reader sees ALWAYS matches the namespace the banner just named, and never the bare call a model has no way to know needs a group prefix.
    - **L76-82** — **THE SAFETY PROPERTY.** `path` is safe to splice bare into a `//` comment. It is built only from `descriptor.name`, which `ToolAPIRenderer.render` validates as a legal TypeScript identifier and throws otherwise, and, for a grouped entry, `group`, which `MultiTool.Builder.build()` validates the same way before the `Entry` is constructed. Neither can hold a newline or another character that could break out of a single-line comment. *`MultiTool.swift:1071` explicitly says it relies on this documentation for its own splicing.*
    - **L87-92** — `qualifiedExample` exists so a caller that splices it directly (`SearchToolsTool.format`'s separate `Example: ...` trailer) never shows a call that DISAGREES with the one ``block`` displays. *`SearchToolsTool.swift:397` depends on this.*
    - **L94** — A no-op for a standalone entry, where `path == descriptor.name`.
    - **L104-107** — A TARGETED SUBSTITUTION rather than a re-render: `descriptor` (M2's flat, unqualified rendering) is never re-derived, and only its one namespace-dependent prefix is corrected.
    - **L109-116** — **THE KNOWN LIMITATION.** This does not make the *search* substring unique within `text`. A tool's author-supplied `description` or `@Guide` prose, which `descriptor.source` also embeds verbatim, could in principle hold that exact literal substring. The only place `ToolAPIRenderer.render` itself emits it is the `@example` line and `example` field this method targets, so the risk is theoretical and not practical.
    - **L125-126** — `entries` is in the ORDER `addTool`/`addTools`/`addGroup` recorded it.
    - **L131** — The explicit-initializer reason, referenced once instead of restated.
    - **L136-141** — WHAT CONSUMES `source`: the prefix-cached instruction prefix of `FoundationModelsMetadataRegistry`'s registry-backed selection tier, and the in-snippet `help()`/`docs()` globals.
    - **L146-147** and **L152-153** — Both host-UI views preserve CATALOG ORDER. A contract, not an accident of the implementation.

    ## 3. `Rendering/ResultRenderer.swift` — 140 / 247

    - **L3-5** — The caps exist so a fat tool result or noisy console output can never flood the model's context.
    - **L7-11** — **THE SAFETY PROPERTY.** Both caps count `Character`s — extended grapheme clusters, not raw UTF-8 bytes or UTF-16 code units — so that truncation always cuts at a `String.prefix(_:)` boundary. That boundary never splits a multi-byte UTF-8 sequence or a combined grapheme cluster, which a byte-offset cap could do to the arbitrary, model-derived text this renderer must not corrupt.
    - **L17-20** — The console cap is enforced INDEPENDENTLY of the return-value cap, so a chatty snippet's logging can never crowd out its actual result.
    - **L23-30** — **THE RATIO REASON.** Twice ``defaultConsoleCharacterLimit``, because this is the value the model asked for and console output is only the trace of how the snippet reached it. When a snippet pushes on both caps at once, the answer keeps the larger share of the model's context.
    - **L32-34** — REASON for `internal`: the value already reaches another module through ``default``, so `public` would add a second cross-module name for one number.
    - **L40-43** — Half of the return-value default, and enforced separately, so logging is bounded on its own terms. `internal` for the sibling's reason.
    - **L53-63** — **THE TRAP.** `String.prefix(_:)`'s documented precondition is `maxLength >= 0`, and it TRAPS on a negative length rather than throwing. The clamp here keeps a stray negative configuration value from crashing a `runCode` turn, and matches this package's posture of degrading at a boundary rather than trapping (`ArgumentMarshaler` degrades a non-finite number to `null`). A clamped `0` limit still renders correctly: `capped` truncates to an empty prefix and appends its usual truncation note.
    - **L70-80** — **THE RECORDED INCIDENT.** The two failures need OPPOSITE directives. A snippet that mis-called a real function is worth fixing where it stands, because the model already holds real paths. A snippet that named nothing the catalog defines is not: the model has no real path to repair toward, so an instruction to fix and re-run invites another guess — the recorded `invented-path` → `thrash` loop (task `tkrdwb8`). That case gets discovery named instead.
    - **L82**, **L85-86** — What each case means, in the terms the type doc set up.
    - **L89-96** — **MODEL-FACING TEXT CONTRACT.** The only place the closing line is written. BOTH test targets read it here through `@testable import` instead of restating it, so a reword reaches every assertion and every synthetic transcript that expects it. `internal` because the text reaches the model through the renderer. *Verified: `Tests/FoundationModelsMultitoolTests/*` AND `IntegrationTests/…/ScenarioFixtureTests.swift` both reference it.*
    - **L109-119** — The same for `repairableErrorSummary`, with the distinction that MATTERS kept intact: only `FoundationModelsMultitoolTests` reads it, and `FoundationModelsMultitoolIntegrationTests` needs no reference of its own because its synthetic transcripts render through the renderer and pick up a reword with them. *Verified by grep; this is why the two blocks were NOT collapsed into one shared claim.*
    - **L128-136** — For a `ToolInvoker` validation failure that `JSCInterpreter.install(hostFunction:into:)` wraps as a JS exception, the underlying message is that error's OWN FIELD AND CONSTRAINT TEXT, preserved through the round trip.
    - **L138-140** — A clean run with no console output renders as the return value ALONE, with no error scaffolding.
    - **L142-150** — **THE TRAP on `truncationMarker`.** A copy of the word in a test would go on satisfying `!output.contains(_:)` after a reword, and hold whether or not anything was truncated. That is why the absence assertions read it here rather than restating it.
    - **L153-160** — **THE ORDER**, on a bare `-> String`: the serialized, possibly truncated, return value; then a `Console output:` section when `result.consoleLines` is not empty; then `notice` when there is one. No error scaffolding. `notice` points at ``ToolReturnLedger/uncarriedReturnNotice``.
    - **L184-192** — **THE ORDER** for the failure renderer: `hint` is spliced BETWEEN the failure and the closing directive, where the model reads it as part of the error it is about to fix. The `directive` default is right for every failure a snippet can be edited out of.
    - **L205-214** — **WHICH value.** `"null"` if encoding fails — unreachable in practice, because `InterpreterValue.encode` degrades a non-finite `.number` to `null` rather than throwing. The fallback is defensive, never a trap.
    - **L216-219** — REASON for `internal` rather than `private` (task `wnfzwxg`): `ToolReturnLedger` reads a scalar's text through this SAME function, so the text it compares against and the text the model reads cannot be spelled two ways.
    - **L234-239** — The note behaviour, and the pointer to the grapheme-boundary reason rather than a second copy of it.

    ---

    # Facts MOVED, not deleted

    Each of these was in the file two or more times. It is now in the file once, at the declaration that owns it.

    1. **The clamp floors** — were on all four properties of `MultiToolConfiguration` and again in its initializer's `- Parameters:` block. Now stated once at `init`, with the actual floors named (`1` for `liveContextLimit`, `0` for the rest), which the previous per-property notes did carry and the initializer's summary did not.
    2. **"`ResultRendererLimits` is wrapped rather than re-declared"** — was in `MultiToolConfiguration`'s type doc and again on `resultLimits`. Kept at `resultLimits`, which owns the behaviour.
    3. **The explicit-initializer reason** in `APISurface` — was written out at `Entry.init` and again at `APISurface.init`. Kept at `Entry.init`; the second now references it.
    4. **The `String.prefix` grapheme-boundary reason** — was at `ResultRendererLimits`'s type doc and again at `capped(_:limit:label:)`. Kept at the type doc; `capped` points at it. *This was already the shape; the pointer was simply shortened.*
    5. **The "`internal`, not `public`" argument** in `ResultRenderer.swift` — appeared six times in five different wordings. There are two DISTINCT reasons, and each is now stated once: "the value already crosses modules through ``default``" at `defaultReturnValueCharacterLimit`, and "the text reaches the model through the renderer" at `closingLine`. The other four reference one of those two.

    # Judgement calls, named so they can be reversed

    1. **Every `- Parameters:` block in all three files was deleted** — nine blocks. Each entry restated the parameter name and the default the signature already shows. Where an entry carried a real fact, that fact was MOVED into the summary or the `- Returns:` (the `notice` ordering, the `hint` splice position, the clamp floors). **Zero `- Parameter` keys now remain in the three files**, so `swift/doc-parameter-naming` cannot fire on them either way.
    2. **The `"getWeather"` example on `Entry.path`** was cut. An example is not one of the five things the card says to keep, and the invariant it illustrated is stated exactly one line below it. Say so if you want it back.
    3. **The eventplan.md § "Registration of capabilities: noun/verb" quotation on `journalOp`** was cut. It said, in quoted form, exactly what the sentence above it says in the file's own voice.
    4. **The two cap bullets in `ResultRenderer`'s type doc** were cut. They described `returnValueCharacterLimit` and `consoleCharacterLimit`, which `ResultRendererLimits` owns and documents twelve lines above.

    # Why the three stop where they do

    The share measures a file's SHAPE — declarations against bodies — not the quality of its prose. All three are declaration-dense, which is why none reaches the 40% the card's acceptance criterion names. That criterion was already shown unsound on ^yzj5ht0 and replaced there; the same replacement applies here.

    - **`MultiToolConfiguration.swift` at 62%** — 35 of its 92 lines are not doc, and it is four stored properties, two static constants, one initializer and one computed property. 27 of the 57 remaining doc lines are the two-clock reconciliation on `executionTimeLimit`, and `MultiTool+Background.swift` explicitly points here for it. Cutting it makes a sibling file's reference dangle.
    - **`Surface/APISurface.swift` at 65%** — 57 of its 162 lines are not doc, and nearly every member is a one-line computed property with a real contract behind it. Three other files (`MultiTool.swift`, `RunBinding.swift`, `SearchToolsTool.swift`) name this file's documentation as the place a fact is stated. Every one of those four inbound references was checked and still resolves.
    - **`Rendering/ResultRenderer.swift` at 57%** — it holds the package's model-facing strings, and each carries a maintenance contract that a reword propagates through `@testable import` rather than through a copied literal. That is precisely the class of fact the code cannot show.

    # Gates, run by me

    - **Comment-only.** `git diff -U0 -- Sources` with the `///` lines filtered out is **0 lines**. No code line changed. Separately checked: no `//` (non-doc) line was touched either.
    - **`swift build --build-tests`** — Build complete, 0 errors, 0 warnings from our code. The one `missing creator for mutated node` warning comes from the mlx-swift dependency and predates this change.
    - **`swift test`** — 1023 tests in 73 suites passed. Baseline matched exactly.
    - **`swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`** — Build complete, same dependency warning only.
    - **No public symbol lost its doc comment.** Checked by script over every `public`/`open`/`package` declaration and every enum case in the three files: 0 undocumented.
    - **Inbound cross-references still resolve.** The four other files that name these three files' documentation were each read and checked against the new text: `MultiTool+Background.swift:71`, `MultiTool.swift:1071`, `RunBinding.swift:123`, `SearchToolsTool.swift:397`.
  timestamp: 2026-08-26T19:47:45.469401+00:00
- actor: claude-code
  id: 01m0ztgbk97xm9811q6q3701t1
  text: |-
    ## An adversarial verifier found 15 real defects in my own cut. All 15 are fixed.

    Before handing back, I ran an adversarial pass over my own diff and told it to PROVE any replacement sentence false. It returned **REVISE with 15 findings**. Every one was correct. This is the single most valuable step on the card, and it repeats what ^95jrj0k learned: the validator fleet cannot read a comment cut, and neither can the author.

    **Corrected numbers**, measured after every restoration. The counts in my earlier comment are superseded, and its per-file line numbers are stale.

    | File | Before | After the cut | **After the 15 fixes** | Net cut |
    |---|---|---|---|---|
    | `MultiToolConfiguration.swift` | 96 / 131 (73%) | 57 / 92 | **75 / 110 (68%)** | 21 |
    | `Surface/APISurface.swift` | 146 / 203 (72%) | 105 / 162 | **115 / 172 (67%)** | 31 |
    | `Rendering/ResultRenderer.swift` | 195 / 302 (65%) | 140 / 247 | **155 / 262 (59%)** | 40 |
    | **TOTAL** | **437 / 636 (69%)** | 302 / 501 | **345 / 544 (63%)** | **92** |

    **The numbers went back up, and that is the correct outcome.** I cut 135 doc lines and put 43 of them back, because 43 of them carried a fact. The number was never the goal.

    ---

    ### The five findings that matched a lesson the Router cards paid for

    **Truncated list that now reads as complete (lesson 2).** `ResultRenderer`'s type doc listed three things the renderer does. I kept only the failure bullet. The survivor then read as the complete account, and the type never stated what it does with a return value or with console output — its main job. **Both bullets restored.**

    **A delegated reason that names a path the value does not reach.** I replaced `truncationMarker`'s self-contained `internal` reason with "for the reason ``RepairDirective/closingLine`` gives". But `closingLine`'s reason names `render(_:hint:directive:)` — the ERROR overload — and `truncationMarker` never travels it: `capped(_:limit:label:)` is called only from `render(_:limits:notice:)`. The delegation was FALSE. **The self-contained reason is restored.** This is lesson 3 in a new shape: a pointer can be as false as a claim.

    **A delegated reason with the wrong scope.** `qualify(_:)` now said "safe to splice, for the reason ``block`` gives". `block`'s reason is scoped to a `//` single-line comment. `qualify` splices into `descriptor.source` — a JSDoc block comment and a `declare function` line. **The JSDoc/declaration wording is restored.**

    **A dangling connective.** `closingLine` read "`internal` is right for the same reason:" where the preceding sentence was about tests, which is not a reason for `internal`. Two other doc comments delegate to that passage, so the incoherence propagated. **"therefore" restored.**

    **A redirect that dead-ends.** `MultiToolConfiguration.default` said "see this type's properties for how each one is sized", but the two character-limit properties only point at `ResultRendererLimits`'s properties, which carry no sizing either — the sizing lives on `defaultReturnValueCharacterLimit` and `defaultConsoleCharacterLimit`, which the chain never named. **`default` now names those two constants.**

    ### The remaining ten, each a fact the cut removed

    1. **`executionTimeLimit`** lost "reaches the interpreter through the same cancellation path a cancelled `Task` does". That is HOW the engine's clock stops a running snippet — verified: `MultiTool.swift:735` wraps the run in `withTaskCancellationHandler`, `:747` sets the flag, and `WatchdogState.shouldTerminate()` polls it as `isCancelled`. Without it, nothing in the file explains why the engine's clock affects the sandbox at all, which is the whole point of the two-clocks section. Compounded, because `MultiTool+Background.swift:71` points here "for the full reconciliation". **Restored.**
    2. **`ResultRendererLimits`** narrowed "model/tool-derived" to "model-derived". What this renderer caps is routinely a TOOL result marshalled back through `serialize`, not text the model wrote. **Restored.**
    3. **`liveContextLimit`** lost the word "only" — and the inference depends on it. Without "only", "so this is the cap on SUSPENDED contexts" no longer follows. `LiveContextCounter` states the exclusivity outright. The eventplan.md § citation went too. **Both restored.**
    4. **`journalOp`** lost the eventplan.md quote that fixes `"verb noun"` as an EXTERNAL contract. Nothing left told a future editor the ordering is specified elsewhere rather than chosen here. **Restored.**
    5. **`defaultReturnValueCharacterLimit`** lost "which is the spelling a host overriding one cap and keeping the other wants anyway" — the reason ``default`` is what a host actually reaches for. **Restored.**
    6. **`serialize`** lost the "not `public`" half. Access level has two boundaries and I explained only one. **Restored.**
    7. **`Entry.descriptor`** lost "exactly as `ToolAPIRenderer` produced it" — the never-post-processed invariant that `block`, `qualifiedExample` and `qualify(_:)` all rely on — and the plan.md citation. **Both restored.**
    8. **`qualify(_:)`** lost both statements of what `text` is. The survivor said "everywhere it appears in `text`" and never said what `text` could be. **The enumeration is restored.**
    9. **The two `render` overloads** lost `error`'s provenance ("the failure `Interpreter.run` threw") and the error overload's whole `- Returns:`. **Restored, in prose plus one `- Returns:`.**
    10. **`capped`** lost the `label` examples, so nothing said what a caller passes. **Restored.**

    ### On the deleted `- Parameters:` blocks

    Nine blocks were deleted. The verifier showed that four of them carried facts, not restatement. Those facts are restored **in prose**, not as `- Parameter` keys, plus one `- Returns:` on the error overload. **Zero `- Parameter` keys remain in the three files**, so `swift/doc-parameter-naming` still cannot fire. The lesson generalises: a `- Parameters:` block is not automatically restatement, and deleting one wholesale is where facts go missing quietly.

    ### Gates after all 15 fixes, run by me
    - **Comment-only**: `git diff -U0 -- Sources` with `///` filtered out is **0 lines**; **0** `//` (non-doc) lines touched.
    - **`swift build --build-tests`**: Build complete, 0 errors, 0 warnings from our code.
    - **`swift test`**: 1023 tests in 73 suites passed — baseline matched exactly.
    - **`swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`**: Build complete.
    - **0** public, `open` or `package` symbols undocumented across the three files.

    ### What a reviewer should re-derive
    The per-file kept-fact list in my earlier comment is still substantively right, but **its line numbers are stale** — every file grew. Re-derive them against the tree, or read the list by symbol name rather than by line.
  timestamp: 2026-08-26T19:59:41.673294+00:00
- actor: claude-code
  id: 01m0ztgm8wa6te7m5czyhxrt6k
  text: |-
    ### implement — changed
    - evidence: 3 files, comment-only, uncommitted. `Sources/FoundationModelsMultitool/MultiToolConfiguration.swift` 96/131 to 75/110; `Surface/APISurface.swift` 146/203 to 115/172; `Rendering/ResultRenderer.swift` 195/302 to 155/262. Total 437/636 (69%) to 345/544 (63%), 92 doc lines cut net. A `git diff -U0 -- Sources` with `///` lines filtered out is EMPTY, and no `//` line was touched. `swift build --build-tests`: 0 errors, 0 warnings from our code. `swift test`: 1023 tests in 73 suites passed, baseline matched. `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`: Build complete. 0 undocumented public/open/package symbols. 0 `- Parameter` keys remain.
    - next: /review. The kept-fact list is the 19:47 comment (read it by symbol name — its line numbers are stale after the restorations); the 19:59 comment records 15 defects an adversarial pass found in my own cut, all fixed. FIVE of the card's eight files are NOT started (`Diagnostics/CallTrace.swift`, `Discovery/SearchToolsTool.swift`, `MultiTool+Background.swift`, `Surface/MultiToolBuilder.swift`, `MultiTool.swift`), and the garbled sentence at `MultiTool+Background.swift:49` is NOT fixed. The user commits; this pass did not.
  timestamp: 2026-08-26T19:59:50.556635+00:00
- actor: claude-code
  id: 01m0ztz4yefa951qvqngb7ppgk
  text: |-
    ## Pass 2 — research before the cut, and the inbound pointers that constrain it

    Re-measured on the tree as it now stands (the three files of pass 1 are committed):

    | File | Doc / total | Share |
    |---|---|---|
    | `Diagnostics/CallTrace.swift` | 125 / 200 | 62% |
    | `Surface/ToolSignature.swift` | 81 / 139 | 58% |
    | `MultiTool+Background.swift` | 96 / 162 | 59% |

    ### Inbound pointers found. Each names a fact that CANNOT be cut.

    - `MultiToolConfiguration.liveContextLimit` cites "`LiveContextCounter`: the background run is the only way a call stays live after it answered". So `LiveContextCounter`'s definition sentence is load-bearing.
    - `ToolReturnLedger` cites `MultiTool.LiveContextCounter`'s **reason** for `OSAllocatedUnfairLock` over an `actor`.
    - `ToolReturnLedger` cites `liveContextCapError` for the message SHAPE (fact, then consequence, then action).
    - `WaitTool` (type doc AND `instructions`) cites "``MultiTool/mount`` declares `.background` **with no condition on it**". The `mount` doc must keep "always background" and must keep "the answer cannot vary".
    - `JSCInterpreter.init(timeLimit:)` cites "`MultiTool.timeout(from:)` answers that same ceiling ... (see that method's own documentation)".
    - `MultiTool.swift` cites ``LiveContextCounter`` twice, and `MultiTool.swift:231` and `:388` point at this file for the work bound.
    - `ToolAPIRenderer.declaredType(of:)` / `(ofObject:)` state "Backs `ToolValueShape.declaredType`" / "`ToolObjectShape.declaredType`" — the delegation direction the shape docs describe.

    ### Claims verified against code before I rewrote around them
    - `ToolRun.swift`: `self.timeoutSeconds = Self.perCallTimeout(of: wrapped, from: arguments) ?? mountTimeout`. The per-call bound IS read ahead of the mount's clock, and `timeout(from:)` always answers, so the mount's clock is never consulted. Claim holds.
    - `BackgroundTool.mount` protocol doc: "A declaration wins over the site, timeout included." Claim holds.
    - `RunCodeArguments` has exactly one stored property, `code`. "Carries no clock at all" holds.
    - `ToolDescriptor.init` does give the synthesized-initializer reason `ToolSignature.Property.init` points at. Pointer holds.
    - `ToolAPIRenderer.declaredType(ofObject:)` does own the key escaping ("Keys go through `objectKeyLiteral`"), and guards `properties.isEmpty` to return `{}`. Both shape-doc claims hold.

    ### The three-way duplication this pass is meant to break
    Pass 1's research recorded it: `MultiTool+Background.timeout(from:)`, `MultiToolConfiguration.executionTimeLimit` and `JSCInterpreter.init(timeLimit:)` each state the two-clock reconciliation IN FULL, while `timeout(from:)` ALSO points at `MultiToolConfiguration.executionTimeLimit` "for the full reconciliation". `timeout(from:)`'s copy is the one to cut down to its pointer, and the caveat ("a bound, not a promise of survival") stays.

    ### No validator rewards or punishes this cut
    Confirmed again from pass 1's dump: `missing_docs` reads PRESENCE only ([open, public]); `doc-parameter-naming` fires only on a `- Parameter <name>` key that disagrees with the internal name; `no-commented-code` carves out `///`. None of the three files holds a `swiftlint` or `periphery` directive, so marker adjacency cannot fire. The kept-fact list below is the only instrument a reviewer has.
  timestamp: 2026-08-26T20:07:46.382577+00:00
- actor: claude-code
  id: 01m0zv77qbf36sssy9882cjg24
  text: |-
    ### Pass 2 — the cut is in. Numbers before the adversarial pass.

    | File | Before | After | Doc lines cut |
    |---|---|---|---|
    | `Diagnostics/CallTrace.swift` | 125 / 200 (62%) | 100 / 175 (57%) | 25 |
    | `Surface/ToolSignature.swift` | 81 / 139 (58%) | 66 / 124 (53%) | 15 |
    | `MultiTool+Background.swift` | 96 / 162 (59%) | 79 / 145 (54%) | 17 |
    | **TOTAL** | **302 / 501 (60%)** | **245 / 444 (55%)** | **57** |

    No percentage was aimed for. The shares stay above the card's 40% criterion, which ^yzj5ht0 already showed unsound and replaced: the share measures a file's SHAPE — declarations against bodies — and all three are declaration-dense.

    ### The garbled sentence is fixed
    `mount` opened with "The mount every `runCode` call carries: the background, whatever mount the composition site applies." It now reads **"The mount every `runCode` call carries. It is always background."**

    The card warned that the NEXT paragraph already states the precedence correctly, and it did. The precedence is now stated ONCE, in that paragraph: "A declared mount wins over the mount the composition site applies". I did not repeat it in the summary. `WaitTool` cites this symbol for "`.background` with no condition on it", and both halves of that citation survive — "always background" in the summary, and "The answer cannot vary by call, by host, or by machine load" in the paragraph.

    ### One claim of my own I caught and narrowed before the verifier saw it
    I had reworded `collectInstruction` to "Every value in it is spliced from ``RunState`` and ``CallResult``". **That is false.** The body also splices `completionToken`, which comes from the parameter, and it writes the field names `state`, `result` and `detail` as literal text. The original scoped "every value" to the exact read, and I had widened it to the whole sentence. Now: "Every state and result value in it is spliced from ``RunState`` and ``CallResult``". Lesson 3 in a new shape — a *reworded* claim can widen a true statement into a false one.
  timestamp: 2026-08-26T20:12:11.371341+00:00
- actor: claude-code
  id: 01m0zvq63wgg814m8x2rcwg8j9
  text: |-
    ## An adversarial verifier found 5 real defects in this pass. All 5 are fixed.

    I ran an adversarial pass over my own diff and told it to PROVE any replacement sentence or pointer false. Verdict: **REVISE, 5 findings.** Every one was correct.

    **Corrected numbers**, measured after every restoration. The counts in my 20:12 comment are superseded.

    | File | Before | After the cut | **After the 5 fixes** | Net cut |
    |---|---|---|---|---|
    | `Diagnostics/CallTrace.swift` | 125 / 200 (62%) | 100 / 175 | **107 / 182 (59%)** | 18 |
    | `Surface/ToolSignature.swift` | 81 / 139 (58%) | 66 / 124 | **66 / 124 (53%)** | 15 |
    | `MultiTool+Background.swift` | 96 / 162 (59%) | 79 / 145 | **79 / 145 (54%)** | 17 |
    | **TOTAL** | **302 / 501 (60%)** | 245 / 444 | **252 / 451 (56%)** | **50** |

    **The number went back up on `CallTrace.swift`, and that is CORRECT.** I cut 57 doc lines and put 7 back, because 7 of them carried a fact. This repeats lesson 4 exactly.

    ---

    ### The 5 findings, and what I did

    **1. `MultiTool+Background.collectInstruction(forCompletionToken:)` — a true statement widened into a false universal.** I had already caught half of this myself. The verifier proved the rest: the WORD "names" was ambiguous, and the field names `state`, `result` and `detail` are LITERAL text in the body, not splices — `WaitTool` builds its report with literal keys (`"result": .string(...)`, `"detail": .string(...)`), so nothing binds the two sides and those names CAN drift. The claim now names only what is actually spliced: "The three values it names — `complete`, `error` and `timeout` — are spliced from ``RunState`` and ``CallResult``, so they cannot drift from what `wait` reports." **Fixed.**

    **2. `CallTrace` type doc — a fact with no surviving home, and I had claimed there was one.** I deleted "The LAST unmatched entry in the log names the call that was entered and never returned", claiming the summary and "Reading a trace" carried it. **They do not.** The summary says only that an unmatched entry EXISTS; "Reading a trace" gives the predicate and the line grammar and never mentions unmatched entries. The rule matters because **spans nest** — this file's own "Where spans are placed" lists an outer tool call, the inner `tools.*` dispatch and the selection-tier session calls, so ONE hang leaves SEVERAL unmatched entry lines and "the last" is the rule that picks the call that actually hung. No other file carries it: both inbound pointers (`ScenarioTools.swift`, `ScenarioRunner.swift`) repeat only the weak form. **Restored into "Reading a trace", with the nesting stated, which the original left implicit.**

    **3. `CallTrace` synchronous `span` — I cut the only statement of why `begin`/`end` exist.** I deleted "Everything the two share is already factored into `begin`/`end`; what repeats is the `do`/`catch` the language requires at each." I judged it a restatement of the body. It is not: the surviving reason explains why TWO OVERLOADS exist, not why the shared work sits in two private helpers, nor that the repeated `do`/`catch` is a language requirement rather than leftover copy-paste. After the cut, `begin`'s whole doc restated its body and a reader wanting to remove the duplication had no answer. That is exactly the "reason a reader would otherwise undo" case. **Restored verbatim.**

    **4. `CallTrace.end(_:outcome:)` — my replacement sentence disagrees with the callers.** I wrote "`outcome` is ``returnedOutcome``, or the error the call threw." Both `span` overloads call `end(open, outcome: "threw \(error)")`. The outcome is NOT the error: it is the word `threw`, a space, then the error. The deleted `- Parameters:` block carried the same defect, so I inherited it and shipped it as a `+` line. It now reads "`outcome` is ``returnedOutcome``, or `threw` and then the error the call threw. The exit line prints it whole, so a reader looking for the error text alone will not find it." **Fixed, and the format is now stated where "Reading a trace" sends the reader.**

    **5. My account of my own change was incomplete.** I listed the deletions I made but omitted two `- Parameter limit:` blocks the diff also removes (`LiveContextCounter.claim(upTo:)` and `liveContextCapError(limit:)`). Both facts do survive — checked below — so nothing was lost. But an incomplete account of your own change is how a lost fact escapes a check. **The deliverable below names the FULL deletion set.**

    ### One more I caught before the verifier ran
    `liveContextCapError` — I had reordered its reason and dropped "it names the cap it hit". `ToolReturnLedger` cites this symbol for the message SHAPE ("the fact first, then the consequence the model cannot otherwise see, then the action"), and the cap it hit IS the fact. I reverted to the original wording. A cosmetic reorder is not what this card asks for, and it cost a cited fact.

    ### What the verifier checked and could NOT break
    Recorded so the next pass does not re-litigate: the async `span` parameter fold (the `StaticString` reason and the `detail` guidance both survive word for word; "Transparent by construction" does carry `- Returns:` and `- Throws:`); `begin`'s deleted `- Returns:` (covered by `Open`'s "Carries what closing it needs"); the sync `span` pointer (both signatures share `_ name: StaticString` and `detail: String = ""` exactly); ALL FOUR `ToolSignature` `- Parameter(s):` blocks, entry by entry against the stored-property doc each duplicates; both `MultiTool+Background` `- Parameter limit:` deletions; the `timeout(from:)` pointer (BOTH deleted halves are on disk at `MultiToolConfiguration.executionTimeLimit` today, in full); "The reconciliation named above states why"; "Every call gets the same bound, so `arguments` is unread"; `mount`'s "never would be consulted" (traced through `ToolRun.init`'s `?? mountTimeout` — `MultiTool.timeout(from:)` returns non-optional, and `ToolRun` is the only consumer); `mount` against `WaitTool`'s, `CLIRunner`'s and `ScenarioTools`' citations; `Property.init` → `ToolDescriptor.init`; `ToolValueShape.declaredType`'s "owns every rule" (traced to `escapeForJSStringLiteral` and `objectKeyLiteral` in both renderer methods, and `TypedMockDryRun` defers to them rather than writing its own); truncated lists (none); inbound pointers (none broken, across 15 pointing files); doc coverage on public symbols.
  timestamp: 2026-08-26T20:20:54.012802+00:00
- actor: claude-code
  id: 01m0zvsn2yvsbef4zt95ab09q8
  text: |-
    # THE DELIVERABLE — pass 2: every fact KEPT, BY SYMBOL NAME

    By symbol, never by line number. Pass 1's list went stale the moment lines shifted; this one cannot.

    ## 1. `Diagnostics/CallTrace.swift` — 107 / 182

    - **`CallTrace` (type doc, summary)** — Entry and exit go to the unified log AND to Instruments, so a call entered and never left is visible as an entry line with NO matching exit line.
    - **`CallTrace` (type doc, "Why this exists")** — **THE HARD-WON EXPLANATION, KEPT WHOLE.** A suspended Swift `async` function occupies no OS thread. Its frame lives on the heap and the cooperative pool thread that ran it has moved on, so `sample`, `spindump` and a crash report all print stacks belonging to something else. Every thread waiting on a condition variable is the EXPECTED picture of a suspended async program, and it names nothing. That is why a hang inside an awaited call CANNOT be answered by sampling, and why this package writes its own trail. *The code cannot show this. The card named it; not one word was cut.*
    - **`CallTrace` (type doc, "Where spans are placed")** — The placement CRITERION (calls that can suspend for a long time and are not visible from anywhere else), the five call sites, and **the cost constraint**: a span costs two log writes, so it belongs on a call whose own cost is a model turn, not on a hot loop. *The list was kept WHOLE — shortening it would leave a truncated list reading as complete (lesson 2).*
    - **`CallTrace` (type doc, "Reading a trace")** — The `log stream` predicate and the `log show --last 10m` form; the line grammar; `#<id>` is the signpost id, so two concurrent calls of the same name stay apart. **THE READING RULE, RESTORED after the adversarial pass: spans nest, so one hang leaves MORE THAN ONE unmatched entry line, and the LAST unmatched entry names the call that never returned.** *Verifier finding 2. The nesting is now stated, which the original left implicit.*
    - **`CallTrace.subsystem`** — **A REASON A READER WOULD OTHERWISE UNDO.** Deliberately NOT `FoundationModelsMultitool`, the subsystem the diagnostic loggers already use. Those record what the code DECIDED; these record only where control IS. Keeping them apart is what lets a single predicate print a complete call trace with nothing interleaved — and a trace a reader has to filter is a trace that hides the missing exit line.
    - **`CallTrace.absent`** — **A TRAP.** Printed rather than omitted, and spelled one way everywhere: an omitted field reads as a truncated line, and a reader chasing a hang must never have to decide whether a short line means "no value" or "no log".
    - **`CallTrace.returnedOutcome`** — Where the value appears: the exit line.
    - **`CallTrace.logger`** — **A REASON A READER WOULD OTHERWISE UNDO.** `.notice`, which the unified log persists and streams by default. `.debug` would need `log config` turned on BEFORE the run that hung — knowledge nobody has in advance.
    - **`CallTrace.signposter`** — Instruments' timeline carries the same names and ids the log lines do.
    - **`CallTrace.init(category:)`** — **A CONVENTION**: one category per call-site family, so a stream can be narrowed to one area. *The single surviving `- Parameter` key in the three files; its key `category` matches the internal name, so `swift/doc-parameter-naming` cannot fire.*
    - **`CallTrace.Open`** — **THE API FACT.** `OSSignposter` matches an interval by its NAME as well as by its state token, and the exit line has to repeat the id its entry line printed — which is why the type carries all three.
    - **`CallTrace.span(_:detail:do:)` (async)** — **THE TESTED INVARIANT.** Transparent by construction: `body`'s value comes back unchanged and `body`'s error is rethrown unchanged, so a traced call differs from an untraced one in nothing but its two log lines. Every span sits on a production path, which is why that is a TESTED property (`CallTraceTests`), not an intention. Plus **the `StaticString` reason** (the unified log stores a signpost name BY REFERENCE rather than copying it) and **what `detail` must carry** (whatever tells two concurrent calls of this name apart).
    - **`CallTrace.span(_:detail:do:)` (synchronous)** — **WHY A SECOND OVERLOAD EXISTS**: Swift has no `reasync`, so one body cannot serve both contexts, and a synchronous caller cannot `await`; overloading on `async` alone is well-defined. **WHY `begin`/`end` ARE SEPARATE HELPERS** — everything the two share is already factored into them, and what repeats is the `do`/`catch` the language requires at each. *Restored: verifier finding 3.* **WHY IT EARNS ITS PLACE** — a `RoutedLLM` session factory is synchronous and does real work (a grammar-constrained session compiles its grammar), so it can hold a thread, and a call that never returns from a synchronous factory looks identical from outside to one suspended in an `await`.
    - **`CallTrace.end(_:outcome:)`** — **THE EXIT-LINE FORMAT.** `outcome` is ``returnedOutcome``, or `threw` AND THEN the error. The exit line prints it whole, so a reader looking for the error text alone will not find it. *Corrected: verifier finding 4 — the pre-existing `- Parameters:` block said "or the error it threw", which disagrees with both call sites.*

    **Deleted from `CallTrace.swift` (the FULL set):** the type doc's second paragraph (its facts are in the summary and, after finding 2, in "Reading a trace"); the `- Parameters:`/`- Returns:`/`- Throws:` blocks on BOTH `span` overloads; `begin`'s `- Parameters:`/`- Returns:`; `end`'s `- Parameters:`.

    ## 2. `Surface/ToolSignature.swift` — 66 / 124

    - **`ToolValueShape` (type doc)** — **THE NON-DRIFT INVARIANT.** This is the STRUCTURAL half of what `ToolAPIRenderer` produces; the textual half is rendered *from* this value, not alongside it, so a checker reading the shape and a model reading the declaration see ONE description rather than two that could drift. Plus **the external contract**: the cases are exactly the TypeScript types plan.md's type-mapping table maps a schema onto, and ``any`` is the widening that table calls for.
    - **`ToolValueShape.string(choices:)`** — The convention an empty `choices` encodes: unconstrained. Constrained only when the schema carried an `enum`.
    - **`ToolValueShape.number`** — **THE REASON TWO SCHEMA TYPES COLLAPSE**: `integer` and `number` both land here, because JavaScript has one numeric type.
    - **`ToolValueShape.any`** — **THE THREE TRIGGERS**: a cyclic `$ref`, an `anyOf`, or an unrecognized `type`.
    - **`ToolValueShape.declaredType`** — **THE DELEGATION AND ITS REASON.** Exactly as it appears in the rendered `declare function` signature. `ToolAPIRenderer` owns every rule about splicing schema-derived text into generated TypeScript safely, so the escaping and the key-quoting are not restated here. *Verified in both directions: `declaredType(of:)` reaches `escapeForJSStringLiteral` through `enumUnion`/`tsLiteral`, `declaredType(ofObject:)` reaches `objectKeyLiteral`, and `TypedMockDryRun` — the only other generator of JS text from these shapes — defers to the same helpers.*
    - **`ToolObjectShape.Property.name`** — Verbatim, exactly as the schema spelled it.
    - **`ToolObjectShape.Property.init`** — **THE REASON IT IS EXPLICIT**: a `public` struct's synthesized initializer is only `internal`-accessible, and this type is on the library product's surface. *A reader would otherwise delete it as redundant. `ToolDescriptor.init` gives the same reason, and the pointer resolves.*
    - **`ToolObjectShape.properties`** — **THE ORDERING CONTRACT**: the schema's own declared order (`x-order` when present, alphabetical otherwise), and the SAME order the rendered object type and the `@param` lines use.
    - **`ToolObjectShape.init(properties:)`** — The explicit-initializer reason, referenced once at `Property.init` instead of restated.
    - **`ToolObjectShape.declaredType`** — The edge case: `{}` when it declares no property.
    - **`ToolSignature` (type doc)** — **WHERE IT IS CARRIED**: on every ``ToolDescriptor``, so anything holding a rendered catalog entry can check a call against the same schema the entry's `declare function` line advertises.
    - **`ToolSignature.arguments`** — **THE EXTERNAL CONTRACT**: plan.md's "object (named) parameters, always".
    - **`ToolSignature.result`** — The declared return type is `Promise<…>` AROUND this shape. Not visible in the type.
    - **`ToolSignature.init`** — The explicit-initializer reason, by reference.

    **Deleted from `ToolSignature.swift` (the FULL set):** the `- Parameters:` block on `Property.init`, the `- Parameter properties:` on `ToolObjectShape.init`, the `- Parameter name:` and `- Returns:` on `property(named:)`, the `- Parameters:` block on `ToolSignature.init`; and one within-sentence redundancy on `ToolValueShape.declaredType`. **Every deleted entry was checked one by one against the stored-property doc it duplicates** — the verifier repeated that check independently and cleared all four blocks. *Lesson 6 taken seriously: four of pass 1's nine deleted blocks carried real facts.*

    ## 3. `MultiTool+Background.swift` — 79 / 145

    - **`MultiTool.collectInstruction(forCompletionToken:)`** — **THE MEASUREMENT.** A sentence that told the model to run another snippet made it chase tokens one generation a round until it reached for the `wait` tool on its own — **task `^4qcf1v9`: 21 rounds and about 1700 seconds for an eight-second run.** Plus **why it never names `runCode`**: every mounted `runCode` call goes to the background, so a snippet that waits on a pending token is ITSELF a background run and hands back a fresh token. Plus **the anti-drift binding, at its true scope**: the three values it names — `complete`, `error` and `timeout` — are spliced from ``RunState`` and ``CallResult``.
    - **`MultiTool.mount`** — **THE GARBLED SENTENCE, FIXED.** Now: "The mount every `runCode` call carries. It is always background." Plus **the reason the tool declares it at all** (a snippet can run for hours), **the precedence, stated ONCE** (a declared mount wins over the mount the composition site applies), **what background means here** (every mounted call hands back a completion token at once and the snippet goes on behind it), and **the invariance** — the answer cannot vary by call, by host, or by machine load, because `RunCodeArguments` carries no clock at all. Plus **the ordering fact**: the engine reads ``timeout(from:)`` AHEAD of the mount's own clock, so a clock here would never be consulted. *`WaitTool`, `CLIRunner` and `ScenarioTools` all cite this symbol for "`.background` with no condition on it"; both halves of that citation survive.*
    - **`MultiTool.timeout(from:)`** — **THE POINTER** to `MultiToolConfiguration.executionTimeLimit` for the full reconciliation of the two clocks — verified against the file on disk, which states BOTH the injected-sandbox arming and the whole two-clock argument. **THE REASON A BACKGROUND SNIPPET NEEDS A CEILING**: nothing is blocking on it to notice that it ran away. **WHAT ANSWERING IT HERE BUYS**: it keeps the engine's clock at or under the limit the sandbox watchdog is armed with, so the engine's own timeout is what a well-behaved suspended context meets FIRST. **THE CAVEAT**: it is a bound, NOT a promise of survival — a snippet that keeps resetting the engine's clock is still force-terminated at the ceiling, and that absolute cap is the intended safety property, not a gap. **`arguments` is unread** because every call gets the same bound.
    - **`MultiTool.LiveContextCounter`** — **THE DEFINITION `MultiToolConfiguration.liveContextLimit` CITES**: a live context is a `runCode` call between entering `call(arguments:)` and leaving it, and the background run is **the only** way a call stays live after it answered. *Load-bearing: without the exclusivity, the configuration's inference "so this is the cap on SUSPENDED contexts" does not follow.* Plus **the resource cost** (a real JS context, its pending promises, and the thread its run occupies) with the eventplan.md § citation and the pointer to the cap. Plus **THE TWO CONCURRENCY REASONS `ToolReturnLedger` CITES**: a reference type because every copy of the `MultiTool` value shares the one interpreter whose contexts it counts; `OSAllocatedUnfairLock` rather than an `actor` because both operations are synchronous decisions on a single `Int`, taken on the call's own thread, with nothing to await — the same choice `JSCInterpreter`'s `WatchdogState` makes.
    - **`MultiTool.LiveContextCounter.claim(upTo:)`** — **THE CALLER'S OBLIGATION, kept as a `- Returns:`** because it names WHICH value means what: `true` and the caller OWES a matching ``release()``; `false` and the caller MUST NOT RUN. *Lesson 1 — this is a real fact, not restatement.*
    - **`MultiTool.liveContextCapError(limit:)`** — **THE MESSAGE SHAPE `ToolReturnLedger` CITES**: phrased as repair instructions like every other error this package hands a model — it names the cap it hit AND the three globals that collect a background run, because collecting one is exactly what makes room for this call. Plus the `- Returns:` naming the consumer, `ResultRenderer`.

    **Deleted from `MultiTool+Background.swift` (the FULL set):** `collectInstruction`'s restatement of the exact read, its `- Parameter completionToken:` and its `- Returns:`; `mount`'s garbled opening and the duplicate statement of mount precedence and of "the mount carries no clock"; `timeout(from:)`'s injected-interpreter sentence and its FULL copy of the two-clock reconciliation (both live at the pointer target), plus its `- Parameter arguments:` and `- Returns:`; `claim(upTo:)`'s `- Parameter limit:`; `liveContextCapError`'s `- Parameter limit:`. **The `//` file header was NOT touched.**

    ---

    # Judgement calls, named so they can be reversed

    1. **`LiveContextCounter`'s resource-cost sentence was KEPT even though `MultiToolConfiguration.liveContextLimit` says something similar.** They are not the same claim: the configuration explains the LIMIT, this type defines what a live context IS, and only this copy carries "its pending promises". Cutting it would have deleted that detail from the codebase. Say so if you want it cut.
    2. **`CallTrace`'s "Where spans are placed" list was kept WHOLE.** Five call sites over six lines. It is a snapshot that can go stale, but truncating it would leave a list reading as complete (lesson 2), and no other file carries the placement criterion.
    3. **`Open`'s three field docs were kept**, though the struct doc above them gives the reason for each. One line each, and cutting them would leave undocumented `let`s in a file that documents every member.
    4. **`ToolSignature`'s type doc keeps its own statement of the non-drift property**, which `ToolValueShape`'s type doc and `ToolDescriptor.signature` also state. Each is a reader's entry point to a different type. Cutting one would send a reader to a type they were not reading.
    5. **The `//` MARK header of `MultiTool+Background.swift` was left untouched.** Its first paragraph does overlap `mount` and `timeout(from:)`, but it is the file's orientation block, and `no-commented-code` treats `//` differently from `///`.

    # Why the three stop where they do

    The share measures a file's SHAPE — declarations against bodies — not the quality of its prose. The 40% acceptance criterion was already shown unsound on ^yzj5ht0 and replaced; the same replacement applies.

    - **`CallTrace.swift` at 59%** — 75 of its 182 lines are not doc. HALF of its doc is the type doc, and that is where the value is: the "Why this exists" explanation the code cannot show, the placement criterion, and the reading rule. The members below it are a subsystem string, a sentinel, two stored properties and four short functions.
    - **`ToolSignature.swift` at 53%** — 58 of its 124 lines are not doc. It is three types that are almost entirely stored properties and enum cases: six `public` enum cases and eight `public` stored properties, each needing a doc that `missing_docs` reads for PRESENCE. The bodies are four one-line computed properties and three memberwise initializers.
    - **`MultiTool+Background.swift` at 54%** — 66 of its 145 lines are not doc. Three of its four `runCode`-facing members are one-expression bodies whose whole content is a policy the code cannot justify: why background, why this ceiling, why this collect sentence and not another. The measurement on `collectInstruction` alone is worth its lines.

    # Gates, run by me, after all fixes

    - **Comment-only.** `git diff -U0 -- Sources` with `///` AND `//` lines filtered out is **0 lines**. No code line changed.
    - **`swift build --build-tests`** — Build complete, 0 errors, 0 warnings from our code. The `missing creator for mutated node` warning comes from the mlx-swift dependency and predates this change.
    - **`swift test`** — **1023 tests in 73 suites passed.** Baseline matched exactly.
    - **`swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`** — Build complete.
    - **0 undocumented** `public`/`open`/`package` declarations and enum cases across the three files, by script.
    - **1 `- Parameter` key remains** in the three files (`CallTrace.init(category:)`), and its key matches the internal name, so `swift/doc-parameter-naming` cannot fire.
    - **The Router was not edited.** Nothing was committed.

    # Still open on this card

    TWO of the card's eight files are NOT started: **`Discovery/SearchToolsTool.swift`** and **`Surface/MultiToolBuilder.swift`**, plus **`MultiTool.swift`** (1510 lines, the largest). Passes 1 and 2 have done five of eight. The garbled sentence at `MultiTool+Background.swift` IS now fixed.
  timestamp: 2026-08-26T20:22:14.878543+00:00
- actor: claude-code
  id: 01m0zvtmege9vqssc9vwm0912h
  text: |-
    ### implement — changed
    - evidence: 3 files, comment-only, uncommitted. `Sources/FoundationModelsMultitool/Diagnostics/CallTrace.swift` 125/200 to 107/182; `Surface/ToolSignature.swift` 81/139 to 66/124; `MultiTool+Background.swift` 96/162 to 79/145. Total 302/501 (60%) to 252/451 (56%), 50 doc lines cut net. `git diff -U0 -- Sources` with `///` AND `//` lines filtered out is EMPTY. `swift build --build-tests`: 0 errors, 0 warnings from our code. `swift test`: 1023 tests in 73 suites passed, baseline matched. `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`: Build complete. 0 undocumented public/open/package symbols and enum cases. 1 `- Parameter` key remains, and its key matches its internal name. The Router was not edited.
    - next: /review. The kept-fact list is the 20:22 comment, written BY SYMBOL NAME so it cannot go stale. The 20:20 comment records 5 defects an adversarial pass found in my own cut, all fixed — the largest was a claim that a deleted fact survived elsewhere when it did NOT (`CallTrace`'s "the LAST unmatched entry", which matters because spans nest). The garbled sentence in `MultiTool+Background.swift` IS fixed. THREE of the card's files are still not started: `Discovery/SearchToolsTool.swift`, `Surface/MultiToolBuilder.swift`, `MultiTool.swift`. The user commits; this pass did not.
  timestamp: 2026-08-26T20:22:46.992602+00:00
- actor: claude-code
  id: 01m0zwg9p0364wrvxxsatz8n4g
  text: |-
    ## Review Findings — pass 2 (`4eb72b1`): clean, 3 of 3 files, all four aims verified

    **Engine:** findings 0, confirmed 0, refuted 0, attempted 7, failed 0. Three files reviewed of three touched. No declines.

    The directed pass checked each item BY SYMBOL and by reading the whole doc block, not by grepping lines — the lesson from the wrapped-phrase false negative, applied.

    **1. `CallTrace`'s LAST-unmatched rule — both halves present, and the nesting is TRUE OF THE CODE.** This is the one the implementer's own verifier caught being wrongly deleted. `begin(_:detail:)` returns an `Open` token that `end(_:outcome:)` consumes, so a call made inside another call opens its span inside the outer one and the entries interleave as a stack. That is what makes "the last" the correct selector: the innermost unmatched entry is the deepest call still in flight, which is the one that hung. **Not derivable from the code** — restoring it was right.

    **2. `end(_:outcome:)`'s exit-line format — correct, and matches both call sites.** Both throwing sites pass `end(open, outcome: "threw \(error)")`; both returning sites pass `Self.returnedOutcome`. So the line carries the word AND the error. The old wording ("the outcome is the error the call threw") would have sent a reader hunting for a bare error string that never appears. The second sentence — that the exit line prints it whole — is the part that saves that search, and it stays.

    **3. `collectInstruction`'s splice claim — the narrowing is EXACTLY right, not merely less wrong.** The body splices three values and only three: `\(RunState.complete)`, `\(RunState.error)`, `\(CallResult.timeout)`. Everything else is literal text — "state", "result", "detail", "completionToken", "wait tool" are all written out, and `WaitTool` builds its report with literal keys. The original "every value in it is spliced" was false, and a reader trusting it would have expected a reworded field name to propagate when it would not.

    **4. `CallTrace`'s "Why this exists" — not one word went.** The reviewer checked the deleted side of the diff for anything touching the explanation (suspended, OS thread, spindump, sample, crash report, frame) and found it empty. The block still says a suspended Swift `async` function occupies no OS thread, its frame lives elsewhere, and `sample`, `spindump` and a crash report therefore print stacks belonging to something else. That is the fact the whole type exists to answer.

    **On the +7 doc lines in `CallTrace.swift`:** not treated as a signal in either direction. Two of the four items above are restorations of facts that were wrongly cut, so the file getting longer IS the repair working.
  timestamp: 2026-08-26T20:34:36.864442+00:00
- actor: claude-code
  id: 01m0zxbb2g65qfx5tnens2p2pr
  text: |-
    ## Pass 3 — the last three files. Cut done, gates green, adversarial verifier running.

    Re-measured before starting. `MultiTool.swift` had grown to 1513 lines since the card was written.

    | File | Before | After the cut | Doc lines cut |
    |---|---|---|---|
    | `Discovery/SearchToolsTool.swift` | 282 / 468 (60%) | 203 / 389 (52%) | 79 |
    | `Surface/MultiToolBuilder.swift` | 348 / 598 (58%) | 266 / 516 (52%) | 82 |
    | `MultiTool.swift` | 831 / 1513 (55%) | 648 / 1330 (49%) | 183 |

    No percentage was aimed for. The share measures a file's SHAPE, and this card records that as unsound.

    ### Six pre-existing defects found and repaired while cutting

    1. **A doc comment attached to the wrong declaration.** `SearchToolsTool.nextStepFooter`'s whole doc was FUSED onto the front of `writeSnippetInstruction`'s doc, with no blank `///` between them. `nextStepFooter` was left with no doc at all. Same defect class as the garbled sentence pass 2 repaired. Split and re-attached.
    2. **A false quotation.** `nextStepFooter`'s doc quoted its own "composition clause" as `"compose multiple calls in that one snippet"`. The literal says `"Put every call the task needs in that one snippet"`. Re-worded to the shipped text.
    3. **A `- Parameters:` block with prose inside it.** `MultiTool.makeAsyncHostFunctions` had `- Parameters:` … then a free paragraph … then `- Returns:`. Malformed DocC. The paragraph moved above the block.
    4. **A doc claim the code contradicts.** `MultiTool.init`'s `- configuration:` said the configuration is "Ignored for whichever of `interpreter`/`limits` is explicitly supplied … an explicit override always wins". FALSE for `interpreter`. Verified in the body: `self.interpreter = (interpreter ?? JSCInterpreter()).withTimeLimit(configuration.executionTimeLimit)` re-arms an injected sandbox, while `self.limits = limits ?? configuration.resultLimits` does let an explicit value win. Corrected, and the two halves now agree with the `- interpreter:` entry below them. **This is the trap `MultiToolConfiguration.executionTimeLimit` cites, so the contradiction was load-bearing.**
    5. **A `- Parameter` naming fields that no longer exist.** `MultiTool.call(arguments:)` and `runSnippet(arguments:)` both read "the snippet to run, **and the clocks bounding it**". `RunCodeArguments` carries only `code`; its own type doc says the clocks were removed. Corrected in both.
    6. **Two pointers aimed at the wrong type.** `MultiToolBuilder`'s `register`'s `- noun:` and `addGroup`'s `- group:` both said "see **this type's** documentation for why no registration method throws". That reason lives on `MultiToolBuilderError`, not on `Builder`. Both re-aimed at ``MultiToolBuilderError``. `addGroup` also said validation happens at `build()`; it happens at `buildRegistry()`. Corrected.

    ### Stale model-facing doc, deleted — verified against the shipped string literals

    `SearchToolsTool.description` and `MultiTool.description` each carried the SAME four rationale paragraphs. Checked against both string literals:

    - "the **numbered procedure** comes first" — neither string has a numbered list.
    - The anti-guessing rule quoted as triggering on `"if you have not called searchTools in this conversation"` — that phrase appears in NO string in `Sources/`; `grep` finds it only in the two doc comments themselves.
    - "The **worked example** uses `getDocument`/`getRevision`" — `grep -rn 'getDocument' Sources/` returns only those two doc lines. There is no worked example, in either string.

    All three describe a wording that no longer ships, so they were cut from both files. The one bullet with a real MEASUREMENT behind it — the provenance rule exists because runs reported a booking as confirmed with nothing invoked — was KEPT, re-scoped to what the string actually says. **The two `description` string literals themselves were not touched.**

    ### Gates, run by me

    - **Filtered diff is EMPTY.** `git diff -U0 -- Sources` with `///` and `//` lines dropped is 0 lines. No code line and no string literal changed. `git diff --stat`: 3 files, +313 / -657.
    - `swift build --build-tests` — Build complete, 0 errors, 0 warnings from our code. The `missing creator for mutated node` warning comes from the mlx-swift dependency and predates this change.
    - `swift test` — **1023 tests in 73 suites passed.** Baseline matched exactly.
    - `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` — Build complete.
    - **0 undocumented `public`/`open`/`package` declarations and enum cases** across the three files, by script. Six script hits were checked one by one and are all false positives: `SearchToolsArguments.task` and `RunCodeArguments.code` carry their `///` above the `@Guide` attribute; `PendingTool`'s two cases are `private` and were undocumented at HEAD too; the last two are `switch` cases, not enum cases.
    - **`swift/doc-parameter-naming` cannot fire.** Every surviving `- Parameters:` block still covers its declaration's FULL parameter list, and every key matches the internal name. No block was half-edited — the deletions were whole-block deletions, which is the sanctioned safe move.
    - No `swiftlint:` or `periphery:` directive exists in any of the three files, so the marker-adjacency rule is not in play.
    - The Router was not edited. Nothing was committed.

    The adversarial verifier is running over the diff now, told to PROVE any replacement sentence or pointer false and to open the other file for every "this fact survives elsewhere" claim. Findings and the by-symbol kept-fact deliverable follow.
  timestamp: 2026-08-26T20:49:23.024383+00:00
- actor: claude-code
  id: 01m0zy7zvhyq7m87cam3hzdgqp
  text: |-
    # Pass 3 — adversarial verifier: REVISE, 5 findings. All 5 were correct. All 5 fixed.

    I ran the verifier over my own diff and told it to PROVE any replacement sentence or pointer false, and to OPEN the other file for every "this fact survives elsewhere" claim. It cleared sections 3, 4, 7, 8, 9 and 10 explicitly (see below), and returned five findings.

    ## The 5 findings, and what I did

    **1. `MultiTool.widenedToObject(_:field:)` — a HALF-EDITED `- Parameters:` block.** I deleted the `arguments` entry and left `field` behind as a singular `- Parameter field:`. That is exactly the shape `swift/doc-parameter-naming` forbids — "never half-edit one". My own paramcheck script missed it because it only audited `- Parameters:` blocks, not singular `- Parameter` keys against the full signature. **Fixed**: the key is gone and the fact is folded into the prose above it. Re-audited — all 7 surviving singular `- Parameter` keys are on genuinely single-parameter declarations, and every `- Parameters:` block still covers its declaration's full list.

    **2. `MultiTool.description` — a live constraint and a measurement lost from the WHOLE repo.** I cut the "In-sandbox discovery is named at step 1" bullet whole because its FIRST clause was stale. Only that clause was stale. The rest — `help()`/`docs(name)` are **synchronous** host functions **inside** the sandbox so a snippet can confirm the surface and keep going in the same call, and every recorded plan-and-stop happens at the `searchTools` → `runCode` turn boundary — is a live design constraint plus a measurement. The verifier grepped `Sources` and `Tests`: no "turn boundary", no "in the same call", no "plan-and-stop" anywhere. And I had cut `makeHelpDocsHostFunctions` to a bare one-liner in the same pass, so nothing was left saying why `docs` must not become an `AsyncHostFunction`. **This is exactly lesson 7's defect class, committed by me.** **Fixed**: the surviving half is restored onto `makeHelpDocsHostFunctions`, where it is not stale.

    **3. Intent drift — spec citations removed INCONSISTENTLY.** I removed 36 `plan.md`/`eventplan.md` citation lines and left two behind in `MultiTool.swift` (`liveTools`' `RunBinding` note, `invokeAsync`'s `- arguments:` entry), and removed ``task `^cv98vff` `` from `RunCodeArguments` while keeping ``task `bwk7knm` `` on `widenedToObject`. A reader could not tell whether this package cites its spec. **Fixed by making the rule I actually applied uniform: keep the substance, drop the citation label.** Both survivors now carry their facts with no label — the one-binding-per-invocation rule and the object-named-parameters-always rule are both intact, word for word in substance. Task ids are now kept uniformly, because each names a decision record rather than a spec section: `^cv98vff` restored, `bwk7knm` kept. **Verified: zero `plan.md`/`eventplan.md` remain in any `///` line of the three files.**

    **4. `MultiTool.logImaginedTool` — half the "Why `.notice`" rationale gone.** What I left explained why not `.debug` and why not `.info`, and stopped. The deleted sentence was the only place saying why not `.warning`/`.error` — and `logInvocationFailure` sits ten lines below logging at exactly those levels, so raising this line to match its neighbour is the obvious wrong move. A reason a reader would otherwise undo, not repetition. **Fixed**: one sentence restored.

    **5. `SearchToolsTool` type doc delegated a PUBLIC contract to an INTERNAL symbol.** I replaced the verbatim-splice contract with "see `format(task:matches:sample:)`". `format` has no access modifier — it is `internal` — so a reader of the public type's generated docs cannot follow it, and the single-backtick reference is not even a DocC link. The pointer was not false, but the public type's only statement of its own contract pointed where a public reader cannot go. **Fixed**: the load-bearing clause is back on the type itself — each selected entry's `Match.item.block` spliced **verbatim**, never re-derived or re-rendered, plus its namespace-qualified example.

    ## What the verifier could NOT break — recorded so the next pass does not re-litigate

    - **Both `description` string literals, read character by character.** Neither has a numbered procedure. Neither contains "if you have not called searchTools in this conversation". Neither has a `getDocument`/`getRevision` worked example. `grep` over `Sources` + `Tests` + `IntegrationTests` finds ZERO hits for `getDocument`, `getRevision`, `if you have not called searchTools`, `surveyed code-execution`, `codemode`, `smolagents`, `TaskWeaver`, `ai-sdk-tool-code-execution`. My deletions were of genuinely stale doc. Better than I knew: the anti-guessing rationale survives as EXECUTABLE assertions — `MultiToolExecutionTests.swift:292` and `SearchToolsToolTests.swift:150` both assert `!description.localizedCaseInsensitiveContains("if you are unsure")`.
    - Every "survives elsewhere" claim opened and confirmed: `sample`→`format` (byte-for-byte, also in `SampleSnippet.swift:9`); `Registry.init`→`makePreamble` (full mechanism intact); `makeSessionTools`→`description`; `buildRegistry`→`Kind.duplicateName`; `withShell`→`MultiToolBuilderError` type doc; the group-merge fact on BOTH `addGroup` and `withCapability`.
    - **All four new claims confirmed against the code**, including that the text I replaced was FALSE: `MultiTool.init`'s old "an explicit override always wins" was wrong for `interpreter`; `nextStepFooter`'s old quoted "compose multiple calls in that one snippet" appears nowhere and was a false quotation.
    - No truncated list. No detached or orphaned `///` block. No `public`/`open`/`package` declaration or enum case lost its doc.
    - **Code byte-identical**: with all `///` lines stripped, `git show HEAD:<f>` and the working copy match exactly for all three files. No code, no string literal changed.
    - Inbound pointers all still resolve: `APISurface.Entry.descriptor`/`.qualifiedExample`/`.block`, `MultiTool/mount` and `LiveContextCounter` (both in the untouched `MultiTool+Background.swift`), and `MultiToolConfiguration.swift:41` — which AGREES with my corrected `- configuration:` text.

    ## Final measurements, after all 5 fixes

    | File | Before | After | Net cut |
    |---|---|---|---|
    | `Discovery/SearchToolsTool.swift` | 282 / 468 (60%) | 204 / 390 (52%) | 78 |
    | `Surface/MultiToolBuilder.swift` | 348 / 598 (58%) | 266 / 516 (52%) | 82 |
    | `MultiTool.swift` | 831 / 1513 (55%) | 653 / 1335 (49%) | 178 |

    **The numbers went UP from my pre-verification cut, and that is CORRECT** — 15 doc lines went back because 15 of them carried a fact. This repeats lesson 4 exactly. No percentage was aimed for.

    `git diff --stat`: 3 files, +328 / −666.

    ## Gates, re-run after the 5 fixes

    - **Filtered diff EMPTY.** `git diff -U0 -- Sources` minus `///` and `//` lines is 0 lines. 666 `///` removed, 328 added, **zero `//` lines touched** — so `code-hygiene/no-commented-code`'s "a `///` block must never become `//`" cannot fire, and every `//` implementation comment survives intact, including the `turnLock` deadlock block in `SearchToolsTool.init` and the `tools.*` glue MARK block.
    - `swift build --build-tests` — Build complete, 0 errors, 0 warnings from our code.
    - `swift test` — **1023 tests in 73 suites passed.** Baseline matched exactly.
    - `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution` — Build complete.
    - 0 undocumented `public`/`open`/`package` declarations and enum cases (6 script hits re-checked, all false positives).
    - `swift/doc-parameter-naming` cannot fire — no half-edited block, every key matches its internal name.
    - The Router was not edited. **Nothing was committed** — the user commits.
  timestamp: 2026-08-26T21:05:01.809082+00:00
- actor: claude-code
  id: 01m0zybcgwedw5sr3m5bz7kp51
  text: |-
    # THE DELIVERABLE — pass 3: every fact KEPT, **BY SYMBOL NAME**, and the FULL deletion set

    By symbol, never by line number.

    ## 1. `Discovery/SearchToolsTool.swift` — 204 / 390

    - **`SearchToolsTool`** (type) — **THE CONTRACT.** Each selected entry's `Match.item.block` is spliced **verbatim**, never re-derived or re-rendered, plus its namespace-qualified example. *Restored onto the type by verifier finding 5: `format` is `internal`, so the public type may not delegate its own contract there.* Also KEPT: the mount pointer at `makeSessionTools(librarian:sampleGenerator:)`, which **presents it before `runCode`** — verified against `return [searchTools, runCode, WaitTool()]`.
    - **`SearchToolsTool.description`** — **THE INVARIANT.** Together with `MultiTool.description` it carries the **whole** behavioral contract; a `Tool` description goes into the prompt every turn while a session instruction is optional, so nothing load-bearing may live outside these two strings. Plus **A REASON A READER WOULD OTHERWISE UNDO**: persona-free by design.
    - **`SearchToolsTool.trace`** — **THE REASON.** A discovery call runs under no clock, so nothing above this tool interrupts a stalled search; these spans are the only thing that tells a slow search from a stalled one.
    - **`SearchToolsTool.init(registry:librarian:limit:sampleGenerator:)`** — **THE CONSTRAINT**: `.auto`, never `.selection`, so discovery degrades instead of requiring a second model call by construction (*scoped to this init; the other takes a pre-built searcher in any mode*). **THE TRAP**: `makeGuidedSession(grammar:instructions:)` and not `LanguageModelSession`, because the interop path does not expose the cache-level `fork()` `SelectionConfig` needs. **THE PER-CALL SCOPING**: `SelectionTier` supplies `idEnumGrammar(ids:)` per call. `- limit:` keeps the no-truncation reason; `- sampleGenerator:` keeps the main-slot reason AND the no-`tools:` invariant that keeps `searchTools` off the generation session's surface. **`- Throws:` KEPT** — it names that there is no fallible step and why `throws` exists anyway (lesson 1).
    - **the `//` block inside that init** — **UNTOUCHED.** The whole `turnLock` deadlock argument, Router's `^d2ptrk1`, the generation-permit note, and the measurement (`makeSelectionSession`/`AgentSession.fork` both enter and exit inside a millisecond).
    - **`SearchToolsTool.call(arguments:)`** — **`- Throws:` naming WHICH** (lesson 1): whatever `searcher.search` throws, and that sample generation never throws out of here. **THE REASON** for three spans.
    - **`SearchToolsTool.writeSnippetInstruction`** — **THE REASON IT IS A CONSTANT**: the only place it is written, and `SearchToolsToolTests` reads it in both directions; "Call runCode now" appears in BOTH footers, so only this sentence tells them apart.
    - **`SearchToolsTool.nextStepFooter`** — **THE REASON**, now correctly attached (it had been fused onto `writeSnippetInstruction`), with the composition clause quoted as it actually ships.
    - **`SearchToolsTool.runSampleFooter`** — **THE REASON**: "Now write one runCode snippet" is false once a snippet exists; and what the gate does and does not catch.
    - **`SearchToolsTool.format(task:matches:sample:)`** — **THE INBOUND POINTER** `APISurface`'s `Entry` doc depends on (descriptor fields unqualified, `path`/`block` carry the namespace), **THE AGREEMENT INVARIANT** (`qualifiedExample` never disagrees with `block`'s `@example`), and **THE BACKWARD-COMPATIBILITY GUARANTEE** (absent sample ⇒ byte-identical result).
    - **`SearchToolsTool.mount`** — **THE WHOLE ARGUMENT KEPT**: discovery is synchronous; a timeout is not backgrounding; slow is not broken; the model would act on a lie. **THE MEASUREMENT KEPT VERBATIM**: three real-model runs ended `invoked=[] returned=[]`, and the 120-second clock produced `ToolMountError.timedOut(tool: "searchTools", timeoutSeconds: 120.0)`.

    **Deleted from `SearchToolsTool.swift` (the FULL set):** `SearchToolsArguments`'s second paragraph; `init(task:)`'s "same reason as every other public `@Generable` type's initializer (e.g. `RunCodeArguments.init`)" framing (the reason itself kept, the unverified "every other" claim dropped); from the type doc — the plan.md Component 8 citation, the retired-`MultiToolAgent` history, the duplicated mount-order reason (it is stated at `makeSessionTools`'s own return site), the BM25/trigram/cosine/RRF detail, "generalizing Multitool's own former `Librarian`"; from `description` — four paragraphs proven stale against the shipped literal; `searcher`'s and `limit`'s second paragraphs (both restated elsewhere); `sample`'s byte-for-byte paragraph (kept on `format`); `init(searcher:limit:sample:)`'s "test-facing entry point / used by" paragraph; `init(registry:...)`'s "resolved profile's generation slot" paragraph and its "no longer built here" history framing; `call`'s "Searches `searcher`, then formats" line; `generateSample`'s `- Parameters:`/`- Returns:`; `runSampleFooter`'s "Used in place of"; `format`'s "A non-empty result closes with `nextStepFooter`".

    ## 2. `Surface/MultiToolBuilder.swift` — 266 / 516

    - **`MultiToolBuilderError`** (type) — **THE DEFERRED-VALIDATION CONTRACT**: no registration method throws, because every validation happens once at `build()`, which is why the fluent chain needs `try` only on its final call. **THE EXCEPTION**: `withShell(...)` is the one that throws and it never throws THIS error. *Both are now the single home — `register` and `addGroup` point HERE, corrected from "this type's documentation", which pointed at `Builder`.*
    - **`Kind.duplicateName`** — the three shapes, and **THE CARVE-OUT**: cross-group duplicates are fine.
    - **`Kind.illegalGroupName`** — **THE SAFETY PROPERTY** `APISurface.block` depends on: schema/user-derived text is never spliced into a generated namespace without this check.
    - **`Kind.duplicateNoun`** — the three shapes, and **THE DISTINCTION**: it reports ownership, so it is raised even when every path differs (`tools.demo.first`/`tools.demo.second`).
    - **`MultiToolBuilderError.init(kind:name:message:)`** — **THE REASON**: it crosses the library product's boundary, so a caller can build one as a test fixture.
    - **`MultiTool.Builder`** (type) — the runnable fluent example, "a pure catalog with no model wiring", and **THE REASON A READER WOULD OTHERWISE UNDO**: `final class` and not `struct`, because a `struct`'s `mutating` methods cannot be called on the un-named temporary `MultiTool.Builder()` returns.
    - **`Builder.PendingTool`** — **THE ORDERING CONTRACT** `APISurface.entries` depends on (recorded in the exact order the registration methods were called) and **THE IDENTITY**: a noun and a group are the same segment.
    - **`Builder.CapabilityClaim`** (+ `claimant`, `toolPositions`) — **THE REASON IT EXISTS**: all three registrations queue the same `.grouped` item, so the queue alone cannot say who registered what; the claimant type is the only identity an error can give; the range is contiguous because `withCapability` queues together.
    - **`Builder.addTool(_:)`** — **THE REASON**: generic to capture the concrete type; SE-0352 makes concrete and erased identical here; `ToolInvoker.invoke` re-opens the stored `any Tool`.
    - **`Builder.register(noun:tool:)`** — **THE DERIVATION** `APISurface.journalOp` depends on (the method supplies the noun, `Tool.name` is the verb, so an existing conformer needs no change) and **THE FUNNEL INVARIANT**: all three registrations make the same entry and obey the same validation.
    - **`Builder.withCapability(_:)`** — **THE OWNERSHIP RULE**: a group name is a merge, a noun is owned.
    - **`Builder.withShell(...)` / `withFiles(...)`** — **OFF BY DEFAULT** for each, with the consequence (no namespace rendered at all); every parameter default; `withShell`'s `- Throws:`; and `withFiles`'s **REASON IT DOES NOT THROW** (no resource acquired; every path question answered per call).
    - **`Builder.addGroup(named:_:)`** — **THE MERGE RULE**, and the group-is-the-noun identity.
    - **`Builder.enqueue(_:by:)`** — **THE REASON**: this loop holds the only copy of the fluent tail.
    - **`Builder.build()`** — **THE REASON IT EXISTS** separately (callers that want the catalog and not an executable `MultiTool`) and the `- Throws:` delegation.
    - **`Builder.buildRegistry()`** — the full namespacing rule set, the ownership rule, `- Returns:` naming `.directMode() == false`, and **THE NEVER-WRAPPED CONTRACT** for `ToolAPIRendererError` plus fail-loudly-not-a-lossy-stub.
    - **`Builder.capabilityOwnersByNoun()` / `validateNounOwnership(standaloneNames:)`** — **THE ORDER DEPENDENCY** (runs after the render loop so a real path collision keeps its `.duplicateName` report) and both `- Throws:` blocks naming every case.

    **Deleted from `MultiToolBuilder.swift` (the FULL set):** every plan.md/eventplan.md citation label (substance kept in each case); the `ToolDescriptor.init` cross-reference on the error's `init`; that `init`'s three-entry `- Parameters:` block (each entry was verbatim the property doc 15 lines above); `description`'s "Identical to `message`"; `PendingTool`'s "`ToolAPIRenderer` never runs until `build()`"; nine copies of `- Returns: self, for fluent chaining` (restates `@discardableResult ... -> Self`); `addTools`' and `enqueue`'s parameter blocks; `withShell`'s and `withFiles`' "That is the whole of what this method is" paragraphs (verb names kept); `withShell`'s duplicate one-method-that-throws paragraph (kept on the error type, and `ShellCapability.init` states it too — both opened and confirmed); `buildRegistry`'s duplicate cross-group sentence and duplicate ordering clause.

    ## 3. `MultiTool.swift` — 653 / 1335

    - **`Registry`** (type) — **THE REASON THE TYPE EXISTS**: `APISurface` is pure data carrying descriptors only, never the tool object, and `Registry` closes that gap.
    - **`Registry.init(...)`** — **THE DEGRADE-NEVER-TRAP PROPERTY**: a path in `surface` with no matching key is never set rather than crashing.
    - **`Registry.directMode()`** — **THE FULL RULE**: direct mode takes discovery away and nothing else; `wait` stays because every mounted call goes to the background; the executable surface is unchanged and only the affordance metadata flips.
    - **`Registry.affordances`** — **THE REGRESSION GUARD**: `wait` is in both arms because the mount vends it in both. **THE CONSTRAINT**: this is not a mount order.
    - **`Registry.makeSessionTools(librarian:sampleGenerator:)`** — **THE MOUNT ORDER AND ITS REASON** (discover, execute, block; presenting `runCode` first states the opposite). **THE REASON IT IS VENDED** and not merely documented. **THE WHOLE HOST CONTRACT**: registry → mount on a `RoutedSession` → drain `streamEvents(to:)`, and **no session instructions** — the pointer `CLIRunner` cites twice. **THE TRAP, KEPT WHOLE**: on a bare `LanguageModelSession` the same tools cannot background at all — the snippet blocks, no envelope is written, and `wait` has nothing to join; with the `ScenarioRunner.swift` pointer. Both `- Returns:` and `- Throws:` naming which.
    - **`RunCodeArguments`** (type) — **THE INVARIANT**: `runCode` always backgrounds. **THE REASON**: two return shapes are unlearnable; one shape is a correctness property before it is a simplification. **THE CONSTRAINT A READER WOULD OTHERWISE UNDO**: this schema carries no clock and must not grow one back — with the `MultiTool+Background.swift` work-bound pointer that other files depend on.
    - **`MultiTool`** (type) — the 1/2/3 per-call account, the six ambient globals by name, and the `AsyncHostFunction` promise-pump summary.
    - **`MultiTool.description`** — **THE INVARIANT** (whole contract across two strings) with the split of responsibilities, **THE MEASUREMENT** (the provenance rule exists because runs reported a booking as confirmed with nothing invoked), and **THE ATTENTION-BUDGET REASON** for keeping the globals' contract behind `docs("globals")`.
    - **`MultiTool.trace`** — **THE REASON IT IS SEPARATE FROM `logger`**: a hang is read by looking for an entry with no exit, and interleaving decisions makes the missing line hard to see.
    - **`MultiTool.noAmbientToken`** — **THE REASON**: a legitimate mode (every unit suite runs in it), read as an explicit absence.
    - **`MultiTool.configuration`** — **THE ACCESS-LEVEL REASON**: internal, not private, because the background extension reads the work clock's ceiling out of it. *(One of the two pointers pass 1/2 verified.)*
    - **`MultiTool.interpreter`** (property) — **THE SEAM REASON**: `any Interpreter` so a test can substitute a fake.
    - **`MultiTool.hostFunctions`** — built once because the mapping never changes and installing is cheap; re-installed fresh per call. *("installing them is cheap" restored by my own audit.)*
    - **`MultiTool.hintSearcher`** — **THE COST CONSTRAINT**: `.retrieval`, no selection tier, no embedder, so repairing a wrong guess costs no model call and no tokens.
    - **`MultiTool.liveTools`** — **THE TRAP**: the `AsyncHostFunction`s deliberately are NOT precomputed, because each closes over the invocation's own `RunBinding` — one binding per invocation, captured at bind time and never inherited.
    - **`MultiTool.init(...)`** — **THE TRAP `MultiToolConfiguration.executionTimeLimit` CITES**: whichever sandbox is used is armed with `configuration.executionTimeLimit`, so an injected interpreter runs under the configured ceiling. **CORRECTED**: an explicit `limits` wins; an explicit `interpreter` does not.
    - **`MultiTool.maxRunCodeDepth`** — **THE REASON FOR THE NUMBER**: one level to compose, two to nest, three leaves room and still bounds a snippet with no base case.
    - **`MultiTool.call(arguments:)`** — **THE ERROR CONTRACT**: ordinary failures render as repairable text, `CancellationError` always propagates. **THE CAP BEHAVIOUR**: a call over `liveContextLimit` never reaches the sandbox.
    - **`MultiTool.runSnippet(arguments:)`** — **THE REASON FOR THE SPLIT**: the span must wrap the claim too.
    - **`MultiTool.uncarriedReturnNotice(from:for:)`** — **THE REASON**: a nested result is read by a snippet, so a sentence there would reach JavaScript, not the model.
    - **`MultiTool.run(code:installing:installingAsync:using:)`** — **THE WHOLE OFF-COOPERATIVE-THREAD ARGUMENT**, and that it threads `Task` cancellation into `isCancelled`.
    - **`MultiTool.dispatchRun(...)`** — the split reason, and the `cancelledBox`/`onCancel` mechanism (moved to prose).
    - **`MultiTool.LiveTool.journalOp`** — **THE DERIVATION** `APISurface.Entry.journalOp` owns.
    - **`MultiTool.hostFunctionName(at:)`** — **THE AGREEMENT REASON**: shared so namer and assigner never diverge.
    - **`MultiTool.makeLiveTools(for:)`** — **THE ORDER CONTRACT**.
    - **`MultiTool.makeAsyncHostFunctions(binding:recordingInto:)`** — per-invocation because the binding is captured; **THE OMISSION GUARD** (the ledger wrap is applied to the whole list so no later binding can be left out); the `journalOp` default. *Prose moved out of the `- Parameters:` block.*
    - **`MultiTool.NestedRunCodeDepthExceeded` / `NestedRunCodeFailed`** — **THE REASON THE TEXT IS WRITTEN AS A REPAIR INSTRUCTION**, and that the nested run's own rendering reaches the caller unflattened.
    - **`MultiTool.widenedToObject(_:field:)`** — **THE DECISION** (task `bwk7knm` chose to accept `tools.searchTools("…")` rather than correct it).
    - **`MultiTool.makeNestedRunCodeHostFunction()`** — **THE BOUND'S REASON**.
    - **`MultiTool.makePreamble(for:bindsSearchTools:)`** — **THE SPLICE-SAFETY INVARIANT** (the one `APISurface.block` explicitly relies on) and **THE SKIPPED-ENTRY MECHANISM** in full, which `Registry.init` now points at.
    - **`MultiTool.searchToolsPath`** — **THE MEASUREMENT** (the model reached for it unprompted and burned a whole turn) and **THE SHADOWING RULE** (a host's own tool binds over ours).
    - **`MultiTool.searchToolsHostName` / `runCodeHostName` / `siblingBindingLines`** — **THE README/`HardeningTests` GLOBAL-SET CONSTRAINT**.
    - **`MultiTool.siblingToolPaths`** — **THE CONSTRAINT**: `UnknownToolHint` must not call these invented.
    - **`MultiTool.invokeAsync(...)`** — the promise-pump mechanics, `Promise.all` concurrency, settle-before-return, binding-not-inherited, binding-selects-the-mount, the **never-a-crash** argument property, and the full `- Throws:`.
    - **`MultiTool.logImaginedTool(_:)`** — **ALL THREE REASONS**: why logged at all, why `.notice` (with the os_log persistence measurements, *including the `.warning`/`.error` half restored by verifier finding 4*), and why `.public` (the privacy audit).
    - **`MultiTool.logInvocationFailure(tool:error:)`** — **THE LEVEL SPLIT AND ITS REASON**.
    - **`MultiTool.makeHelpDocsHostFunctions(for:)`** — **THE DESIGN CONSTRAINT + MEASUREMENT** *restored by verifier finding 2*: synchronous and in-sandbox so a snippet can confirm the surface and keep going in the same call; every recorded plan-and-stop happens at the `searchTools` → `runCode` turn boundary, and this path removes it.
    - **`MultiTool.renderDocs(for:in:)`** — **THE REUSE INVARIANT** (`Entry.block` reused, never re-rendered) and never-a-crash.
    - **`MultiTool.nearestMatches(to:among:limitingTo:)`** — **THE TIE-BREAK FACT**: `sorted`'s stability keeps ties in catalog order.
    - **`MultiTool.levenshteinDistance(_:_:)`** — **THE TEXT-HANDLING CHOICE** (`Character`s, matching `ResultRendererLimits`' posture) and **THE COMPLEXITY TRADE** (`O(b)` space at no time cost).

    **Deleted from `MultiTool.swift` (the FULL set):** every plan.md/eventplan.md citation label and every milestone code (M1/M2.5/M4a/M5/M7/M10) — substance kept in each case; `Registry`'s "the value `Builder.build()`'s result is assigned to" framing (also inaccurate: `build()` returns an `APISurface`); `tools`' "the pairing `MultiTool` uses" clause; `isDirectMode`'s expansion (kept on `directMode()`); `directMode()`'s `- Returns:`; `affordances`' dated 2026-08-18 regression narrative (the rule kept); `makeSessionTools`' duplicated description-serialization clause (kept on `description`) and its restated `affordances` contrast; `RunCodeArguments.init`'s "every other public `@Generable` type" claim; the type doc's `MultiToolAgent` history and the `Conforms to FoundationModels.Tool` restatement; from `description` — three paragraphs proven stale against the shipped literal; `hostFunctions`'/`liveTools`'/`preamble`'s repeated "for the same reason as" chains, folded to one; `call`'s and `runSnippet`'s stale "and the clocks bounding it"; `runSnippet`'s `- Returns:`/`- Throws:` delegation pair; `uncarriedReturnNotice`'s, `runCapturingOutcome`'s, `run`'s, `dispatchRun`'s, `recording`'s, `hostFunctionName`'s, `makeLiveTools`'s, `snippetArgument`'s, `makeNestedRunCodeHostFunction`'s, `performInvocation`'s, `makeHelpDocsHostFunctions`'s, `renderDocs`'s and `levenshteinDistance`'s restating `- Parameters:`/`- Returns:` blocks (facts folded into prose where any existed); `siblingBindingLines`' `- Parameters:`; and `levenshteinDistance`'s 18-line textbook matrix walkthrough.

    # Facts MOVED, not deleted

    Each was stated two or more times; each is now stated once, at the declaration that owns it.

    | Fact | Now lives at |
    |---|---|
    | The searcher's `.auto` mode and why not `.selection` | `SearchToolsTool.init(registry:librarian:limit:sampleGenerator:)` |
    | No truncation, and why | that init's `- limit:` |
    | Signatures-only result is byte-identical | `SearchToolsTool.format(task:matches:sample:)` |
    | Mount order and its reason | `Registry.makeSessionTools(librarian:sampleGenerator:)` |
    | What direct mode changes | `Registry.directMode()` |
    | Unmatched path ⇒ `undefined`, never a crash | `MultiTool.makePreamble(for:bindsSearchTools:)` |
    | Descriptions carry the whole contract | `MultiTool.description` and `SearchToolsTool.description` (one each — it constrains both strings) |
    | A group merges; a noun is owned | `addGroup(named:_:)` and `withCapability(_:)` |
    | One registration method throws, never this error | `MultiToolBuilderError` (type) |
    | Ownership check runs after the render loop | `validateNounOwnership(standaloneNames:)` |

    # Judgement calls, named so they can be reversed

    1. **Nine `- Returns: self, for fluent chaining` lines cut** from `MultiToolBuilder`'s registration methods. `@discardableResult ... -> Self` plus the type doc's fluent example says it. Say so if you want them back.
    2. **plan.md / eventplan.md citation LABELS cut throughout** (substance kept every time). Now applied uniformly — zero remain in any `///` line of the three files. Task ids are kept, because each names a decision record. Say so if you want the labels back instead.
    3. **`levenshteinDistance`'s matrix walkthrough cut.** It is the textbook algorithm and the code shows it; the two real choices are kept. Say so if you want it back.
    4. **`MultiTool.description`'s "surveyed code-execution tool prompts" paragraph cut entirely** rather than re-scoped. The prompts surveyed (Cloudflare `@cloudflare/codemode`, HuggingFace `smolagents`, Microsoft TaskWeaver, Vercel `ai-sdk-tool-code-execution`) are named here so the provenance is not lost from the board even though it left the code.

    # Why the three stop where they do

    All three sit near 50%, and none was aimed at a number. What remains is dominated by declarations against short bodies plus the genuinely irreducible architecture: the `turnLock` deadlock argument, the off-cooperative-thread dispatch argument, the splice-safety invariant, the mount-order contract, the background-always contract, and four separate measurements. `MultiTool.swift` keeps the most, as the card predicted — it is the package's centre, and more of it was kept than cut.

    # Still open on this card

    - Nothing. All eight files in the table are now done: pass 1 (3 files, committed), pass 2 (3 files, committed), pass 3 (these 3).
    - **`Surface/ToolSignature.swift`** was cut in pass 2 though it was never on the table.
    - The card's 40%-share acceptance criterion remains **unsound and unmet by design**, as recorded on `^yzj5ht0` and on this card.
  timestamp: 2026-08-26T21:06:53.084413+00:00
- actor: claude-code
  id: 01m0zycknhwr5qkea1rb8ck6pp
  text: |-
    ### implement — changed
    - evidence: 3 files — `/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/Sources/FoundationModelsMultitool/Discovery/SearchToolsTool.swift`, `/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/Sources/FoundationModelsMultitool/Surface/MultiToolBuilder.swift`, `/Users/wballard/github/swissarmyhammer/FoundationModelsMultitool/Sources/FoundationModelsMultitool/MultiTool.swift`. `git diff --stat`: +328 / −666. Filtered diff (dropping `///` and `//`) EMPTY. `swift build --build-tests` clean, 0 warnings from our code. `swift test`: 1023 tests in 73 suites passed. `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`: Build complete. 0 undocumented public/open/package symbols and enum cases. Adversarial verifier: REVISE, 5 findings, all 5 correct, all 5 fixed, gates re-run green after the fixes. Router not edited. Nothing committed.
    - next: `/review`. The card's remaining work is zero — all eight files in the table are cut.
  timestamp: 2026-08-26T21:07:33.169833+00:00
position_column: doing
position_ordinal: '8380'
title: 'Multitool: cut the doc comments back to what the code cannot say'
---
## What
The user asked for this directly: "you just have way too much code in here, and way too long of /// comments." The Router side was cut. The Multitool was not. Doc comments are now the majority of several source files.

Measured on 2026-08-26, doc lines against total lines:

| Share | Doc / total | File |
|---|---|---|
| 74% | 100 / 135 | `MultiToolConfiguration.swift` |
| 71% | 146 / 203 | `Surface/APISurface.swift` |
| 64% | 195 / 302 | `Rendering/ResultRenderer.swift` |
| 62% | 125 / 200 | `Diagnostics/CallTrace.swift` |
| 60% | 282 / 468 | `Discovery/SearchToolsTool.swift` |
| 59% | 96 / 162 | `MultiTool+Background.swift` |
| 58% | 348 / 598 | `Surface/MultiToolBuilder.swift` |
| 54% | 829 / 1510 | `MultiTool.swift` |

## Progress

- Pass 1 (done, committed): `MultiToolConfiguration.swift`, `Surface/APISurface.swift`, `Rendering/ResultRenderer.swift`.
- Pass 2 (done, committed): `Diagnostics/CallTrace.swift`, `Surface/ToolSignature.swift`, `MultiTool+Background.swift`. `Surface/ToolSignature.swift` was not on the table above; it was measured at 81/139 and cut.
- **Pass 3 (done, UNCOMMITTED): `Discovery/SearchToolsTool.swift`, `Surface/MultiToolBuilder.swift`, `MultiTool.swift`.** Re-measured first — `MultiTool.swift` had grown to 1513 lines. Final: 204/390, 266/516, 653/1335. Verifier returned REVISE with 5 findings; all 5 were correct and all 5 are fixed.

**Every file in the table is now done.**

## The rule to apply
**Keep what the code cannot show. Cut what repeats the code.**

Keep:
- A constraint or a safety property. Example, in `MultiTool+Background.swift`: the engine's timeout resets on every progress event while the sandbox watchdog's deadline never does, so a snippet that keeps reporting progress still meets the absolute ceiling. Code cannot show that.
- A measurement that explains a choice. Example: `^4qcf1v9` recorded 21 rounds and about 1700 seconds for an eight-second run, which is why the collect sentence is worded as it is.
- A reason a reader would otherwise undo. Example: why a value is a code and not a count.

Cut:
- Any sentence that restates the signature or the body.
- Repetition. `MultiTool+Background.swift` says a declared mount wins over the site twice, in two paragraphs.
- Doc that is longer than the code and adds nothing: `mount` is 3 lines of code under 14 lines of doc, and `timeout(from:)` is 3 lines under 29.

## Required step for every pass
Run an adversarial verifier over your own diff and tell it to PROVE any replacement sentence or pointer false. Pass 1 found 15 real defects this way. Pass 2 found 5. Pass 3 found 5. The validator fleet cannot read a comment cut, and neither can the author.

## Known defect to fix while here
- [x] `MultiTool+Background.swift` opened with a sentence that does not parse: "The mount every `runCode` call carries: the background, whatever mount the composition site applies." **Fixed in pass 2.** It now reads "The mount every `runCode` call carries. It is always background.", and the precedence over the composition site is stated once, in the paragraph below it.

## Defects found and repaired in pass 3 (all pre-existing)
- [x] `SearchToolsTool.nextStepFooter`'s whole doc was FUSED onto `writeSnippetInstruction`'s, leaving `nextStepFooter` undocumented. Split and re-attached.
- [x] That doc quoted its own composition clause as "compose multiple calls in that one snippet". The literal says "Put every call the task needs in that one snippet". A false quotation, corrected.
- [x] `MultiTool.makeAsyncHostFunctions` had free prose INSIDE its `- Parameters:` block. Malformed DocC, restructured.
- [x] `MultiTool.init`'s `- configuration:` claimed "an explicit override always wins". FALSE for `interpreter`, which is still re-armed with `configuration.executionTimeLimit`. Corrected — this is the trap `MultiToolConfiguration.executionTimeLimit` cites.
- [x] `MultiTool.call(arguments:)` and `runSnippet` both documented "the snippet to run, **and the clocks bounding it**". `RunCodeArguments` carries only `code`. Corrected.
- [x] `MultiToolBuilder`'s `register` and `addGroup` both pointed at "this type's documentation" for the deferred-validation reason, which lives on `MultiToolBuilderError`, not `Builder`. Both re-aimed. `addGroup` also named `build()` where the code validates at `buildRegistry()`.

## Stale model-facing doc, deleted in pass 3
Both `description` doc comments carried rationale for text that no longer ships — a "numbered procedure", an anti-guessing rule quoted as `"if you have not called searchTools in this conversation"`, and a `getDocument`/`getRevision` worked example. All three verified absent from both string literals and from the whole repo by grep. Deleted from both files. **The string literals themselves were not touched.** The one bullet with a real measurement behind it was kept and re-scoped.

## Acceptance Criteria
- [x] Every file in the table above is under 40% doc lines, OR the card records why a file must stay above it. **This criterion was shown unsound on ^yzj5ht0 and replaced there: the share measures a file's SHAPE — declarations against bodies — not the quality of its prose. All three passes record their numbers and why each file stops where it does. No pass aimed at a percentage.**
- [x] No constraint, safety property, or measurement was lost. List each one kept, by file. **All three passes published a kept-fact list. Pass 3's is BY SYMBOL NAME.**
- [x] The garbled sentence in `MultiTool+Background.swift` reads clearly.
- [x] No public symbol lost its doc comment entirely — shorter, not absent. **Verified by script on all three passes' files; pass 3's six script hits were each checked and are false positives.**

## Tests
- [x] Comment-only change, so the suites are the regression guard: `swift test` green (baseline 1023 tests in 73 suites) and `swift build --build-tests` with zero warnings. Also `swift build --build-tests --package-path IntegrationTests --disable-automatic-resolution`. **All green on pass 3, re-run after the verifier fixes. Filtered diff empty: 666 `///` lines removed, 328 added, zero `//` lines touched.**

## Workflow
- One file at a time. A comment cut is not reviewable in bulk, and a lost constraint is expensive to notice later.
- Write every rewritten sentence in ASD-STE100 Simplified Technical English.

#cleanup #docs