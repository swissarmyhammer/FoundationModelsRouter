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

## Known defect to fix while here
- [ ] `MultiTool+Background.swift:49` opens with a sentence that does not parse: "The mount every `runCode` call carries: the background, whatever mount the composition site applies." Replace with one clear sentence, for example: "The mount every `runCode` call carries. It is always background, and it wins over the mount the composition site applies."

## Acceptance Criteria
- [ ] Every file in the table above is under 40% doc lines, OR the card records why a file must stay above it.
- [ ] No constraint, safety property, or measurement was lost. List each one kept, by file.
- [ ] The garbled sentence at `MultiTool+Background.swift:49` reads clearly.
- [ ] No public symbol lost its doc comment entirely — shorter, not absent.

## Tests
- [ ] Comment-only change, so the suites are the regression guard: `swift test` green (baseline 1023 tests in 73 suites) and `swift build --build-tests` with zero warnings.

## Workflow
- One file at a time. A comment cut is not reviewable in bulk, and a lost constraint is expensive to notice later.
- Write every rewritten sentence in ASD-STE100 Simplified Technical English.

#cleanup #docs