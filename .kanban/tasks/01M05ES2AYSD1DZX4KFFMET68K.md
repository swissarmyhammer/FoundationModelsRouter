---
assignees:
- claude-code
position_column: todo
position_ordinal: '8480'
title: The public LanguageModelProfile initializer lets a consumer defeat per-container serialization
---
A consumer can build two handles over one resident container and get two separate generation gates. Two gates over one container permit two concurrent generations. That is the exact condition the gate exists to prevent.

This is the reverse of the deadlock on `^1zt7vyg`. That card is a liveness failure — something that must run does not. This card is a safety failure — something that must not run concurrently can.

## How a consumer reaches it

- `LanguageModelProfile.init(...)` is `public` and takes `generationGate: AsyncSemaphore? = nil` (`Sources/FoundationModelsRouter/LanguageModelProfile.swift:178`, `:188`).
- `AsyncSemaphore` is `public`, and `init(value:)` is `public` (`Sources/FoundationModelsRouter/Concurrency/AsyncSemaphore.swift:32`, `:47`).
- When the parameter is `nil`, the initializer mints a fresh gate (`LanguageModelProfile.swift:199`).

The resolver path is safe. `Router` gives the same gate instance to every handle over one `PoolEntry` (`Router.swift:953`), so resolved handles contend correctly.

The direct path is not safe. Nothing makes a consumer supply the container's own gate, and nothing tells them one exists.

## Why the documentation does not protect us

`LanguageModelProfile.swift:136-137` says the fresh gate matches "the pre-pooling behavior for a handle constructed directly (e.g. in tests)". "e.g. in tests" is guidance, not a constraint. The type does not enforce it, and the initializer is public.

Six of our own gated suites already build `standard` and `flash` handles over one container this way and pass no gate. If our own suites take the unsafe path by default, a consumer will.

## Why nobody has reported it

The `FoundationModelsMultitool` session checked their tree and found no construction of a profile, a handle, or a semaphore. Every handle they hold comes from `router.resolve(profile:reporting:)`.

They ask that this is not recorded as care. They only ever needed a resolved profile. Nobody weighed the alternative. A consumer that reaches for the public initializer to avoid resolution — a test double, a fixed pin, or a warm handle held across resolutions — lands here with no warning.

## Note on the risk

The gate is a throughput constraint, not a safety constraint. See `^1zt7vyg` for that evidence, and note that Apple's `ModelContainer` gives exclusive access below us. So two concurrent generations queue at the container. They do not corrupt state.

Do not use that to close this card. Two handles over one container silently lose the serialization the gate exists to give, and the consumer gets no signal. Decide the correct behaviour deliberately rather than by default.

## Options to weigh

- Remove `generationGate` from the public initializer, and give tests a separate entry point.
- Keep the parameter but make the gate come from the container, so a direct handle shares it.
- Keep it and give a clear warning when two handles over one container hold different gates.

## Acceptance Criteria

- [ ] Recorded which behaviour is correct for a directly constructed handle over an already-resident container
- [ ] A consumer cannot silently obtain two gates over one container, or is warned when they do
- [ ] The "e.g. in tests" wording becomes a constraint, or the documentation states the hazard plainly
- [ ] Our own gated suites use the resolver path, or state why a hand-built handle is correct for that test
- [ ] A test covers the two-handles-one-container case

Related: `^1zt7vyg` (the deadlock), `^trwcs63` (the coverage gap that hid both). #bug #api #nested-generation