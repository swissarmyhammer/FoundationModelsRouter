---
position_column: todo
position_ordinal: '8180'
title: 'Pooled model residency: per-project profiles sharing one budget'
---
## What

**Upstream ask from `FoundationModelsACPAgent`** (its `plan.md` §9.1). Pairs with `ke41yth` (per-session recording root) — both fall out of the same change: that package now resolves **configuration per project root**, so two concurrent ACP sessions in different repos are no longer guaranteed to want the same thing.

Config is layered per session cwd, and a project's `.<name>/config.yaml` may name its own `profile:`. So a repo that pins a particular coding model should get it, while a session in another repo keeps its own. Today that is impossible: a Router has one resident profile, so the consumer degrades to "log a warning and reuse whatever is already loaded." It ships that way as a stopgap and wants it gone.

## The correctness constraint, which is sharper than the optimization

The obvious framing is deduplication — two projects naming the same model should share one loaded copy instead of paying for it twice. True, and worth having. But the load-bearing requirement is stricter:

**The memory budget must have exactly one authority.**

`runJointFit(profile:budget:metadataByRef:)` prices one profile's models against the machine budget (`headroomReserve`, the `probe`). Two Routers each running that against the *whole* budget will each independently conclude they can afford a large model, and together they will exhaust GPU memory. Whatever shape this takes, there must be a single place that decides what is resident and what gets evicted — the joint fit has to price the **union** of resident models, not one profile at a time.

That makes pooling a correctness requirement for multi-profile operation, not a nice-to-have.

## What is already right

- **The generation gate is already on the model, not the Router.** `LanguageModelProfile.generationGate` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:130`), because "MLX generation runs a single GPU stream and is not safe to interleave." A shared model therefore already carries the gate that stops two borrowers interleaving on it — the piece that would have been hardest to retrofit.
- **Slot-level dedupe is the existing precedent.** `slotMembership(profile:) -> [ModelRef: Set<ModelSlot>]` (`Router.swift:394`) already handles one `ModelRef` serving several slots within a profile. This ask is the same idea one level up: one `ModelRef` serving several *profiles*.
- **`residencyState` is the constraint** (`Router.swift:304`) — a single resident set per Router is what has to generalize.

## Shape — left to Router, with the requirement stated

Either reading satisfies the constraint, and the choice belongs with Router:

- **One Router, several resident profiles.** Sessions name the profile they want; Router dedupes `ModelRef`s across profiles and runs one joint fit over the union. Keeps a single owner of GPU memory, which is what you want when memory is the scarce resource.
- **Several Routers, one shared pool.** The pool owns residency, refcounts by `ModelRef`, and is the single evictor; Routers borrow. Matches the consumer's mental model but adds a third participant to every memory decision.

Requirements either way:

- Residency keyed on whatever actually determines the loaded artifact — `ModelRef` including revision, plus quantization and any load-time parameter that changes the resident bytes. Two profiles naming the same thing share one instance; two naming different revisions do not.
- Reference counted, with a defined eviction policy when the budget is exceeded (and a defined answer for "a model is wanted but nothing can be evicted" — fail the session honestly rather than OOM).
- A model stays loaded while any session references it; unloading is safe only at zero.
- The joint fit prices the union of resident models against one budget.

## Acceptance Criteria

- [ ] Two sessions with different profiles can be live at once, each generating with its own model.
- [ ] Two sessions naming the same model share one loaded instance (verifiable: loaded-model count, not just behavior).
- [ ] Total resident footprint respects the single budget; the second profile cannot push past `headroomReserve`.
- [ ] A model is evicted only when no session references it.
- [ ] When a requested model cannot fit and nothing is evictable, the session fails with a clear error rather than exhausting memory.
- [ ] Single-profile callers are unaffected.

## Tests

- [ ] Two profiles sharing a `ModelRef` → one load, two live sessions, both generate.
- [ ] Two profiles with disjoint refs → both resident, total within budget.
- [ ] Two profiles whose union exceeds the budget → defined, non-OOM outcome.
- [ ] Releasing one session keeps a shared model loaded for the other; releasing both unloads it.
- [ ] Concurrent generation on a shared model serializes on the model's `generationGate`.
- [ ] Same-ref-different-revision does **not** share.

## Workflow

- Use `/tdd` — write failing tests first, then implement to make them pass.