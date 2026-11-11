# Decisions

A resolved profile has four slots: `standard`, `flash`, `embedding` and
`decision`. The `decision` slot answers questions about a state with
probabilities. It reads the probabilities from the model. It generates no text.

## The slot

- The slot is `ModelSlot.decision`. Its wire form is `"decision"`.
- The handle is `profile.decision`, of type `RoutedDecider`
  (`RoutedModel<any LoadedDecisionContainer>`).
- The pool role of the slot is `ModelRole.llm`. A decision model is an LLM, and
  its log probabilities give the answers. Thus a decision model and a
  generation model of the same pool key are one resident model.
- The decision types (`DecisionState`, `DecisionSession`, `Question`) come from
  the `FoundationModelsDecision` package. Import it next to
  `FoundationModelsRouter`.

```swift
import FoundationModelsDecision
import FoundationModelsRouter

let session = profile.decision.makeSession(state: .text(ticket))
let urgency = try await session.probability(of: "Does this convey urgency?")
```

`makeSession(state:)` makes a new `DecisionSession` about one state. The
questions of a session are independent: an answer is never history for a later
question. A session also has `choice(_:from:)` and `score(_:levels:)`.

A tool takes the handle in its initializer, as with the other slots. See
`DecideTool` in `Sources/FoundationModelsRouter/Tools.swift`.

## The default candidate

`ProfileDefinition.decision` is the list of decision candidates, in preference
order. When a profile gives no list, it gets
`ProfileDefinition.defaultDecisionCandidates`:

```text
Mapika/decider-4b-GGUF/decider-4b-v3-Q4_K_M.gguf
```

This is the `decider-4b` model, quantized to `Q4_K_M`, in GGUF format. An empty
list is also valid. The slot then always uses the `flash` model.

## The prompt format

The router selects the prompt format from the repository of the chosen model:

| The repository root | The prompt format |
|---|---|
| has a `decider_config.json` file | `DeciderPromptFormat`, with the configuration of that file |
| has no `decider_config.json` file | `GenericPromptFormat`, which works with any instruct model |

The router reads `decider_config.json` through the metadata source of the
sizing step, at the revision of the model reference. A local folder records the
file at its top, as a Hub repository does.

The flash fallback always uses `GenericPromptFormat`, and it reads no file.

`GenericPromptFormat` turns reasoning off in the chat template. Some chat
templates ignore this request and leave a thinking block open (`<think>` or
`<|channel>thought`). A thinking block before the answer gives incorrect
probabilities. Thus the format does not close the block. It throws
`DecisionError.unsupportedModel` at the first question.

## The memory rule

The decision pass runs after the trio (`embedding`, `standard` and `flash`) is
chosen:

1. The trio is fitted first. The decision slot does not take part in that fit.
   Thus the decision slot cannot make the trio choose a smaller model or a
   smaller context.
2. The decision pass gets only the memory that the trio leaves. It uses the
   context of the trio.
3. The pass tries each decision candidate in preference order. The first
   candidate that fits wins.
4. A candidate with the same pool key as a model of the trio is the same
   resident model. It costs 0 more bytes.

## The flash fallback

When no decision candidate fits, the slot uses the `flash` model. Thus the
decision slot never stops a resolve, also when the profile gives no candidate.

The slot also uses the `flash` model when the router cannot read the prompt
format of the chosen candidate (for example, `decider_config.json` is not
valid). The router then logs a warning on the
`FoundationModelsRouter.RepoMetadataReader` logger: "the prompt format of the
decision model could not be read; the decision slot uses the flash model". The
metadata of the warning gives the model reference and the type of the error.

To see if a resolved profile uses the flash fallback:

- `profile.decision.chosen` is equal to `profile.flash.chosen`.
- `profile.decision.footprintBytes` is 0, because the model is resident one
  time.
- The `FoundationModelsRouter.resolve` span has the attribute
  `model.ref.decision`, with the same value as `model.ref.flash`.

### The rejections in the resolution

The resolution of the slot records why each candidate was rejected. Code in
this package and in its test targets reads it from
`profile.decision.resolution`, which has `package` access:

- `fallback` is `SlotFallback.flashModel` when the slot uses the `flash` model,
  else `nil`.
- `considered` holds one `CandidateReport` for each decision candidate, in
  preference order. Its `verdict` tells the result:

| Verdict | Meaning |
|---|---|
| `chosen` | The candidate fits, and the slot uses it. |
| `tooLarge` | The candidate needs more bytes than the trio left. |
| `skippedHigherPreferenceChosen` | A candidate earlier in the list won. The router did not size this one. |
| `metadataUnavailable(reason)` | The router could not size the candidate, or could not read its prompt format. `reason` tells why. |

`ResolutionProgress.slots[.decision]?.chosen` gives the model of the slot
during the resolve, with the fallback applied.

### A model that gives no log probabilities

If the model of the slot gives no log probabilities, the resolve does not fail.
The first decision of a session throws
`PooledLogitsModelError.notLogitsCapable`.

## No transcript entry

A decision writes nothing to the transcript, the same as an embed call. A
decision is not part of the conversation of a session. The session record of
a root session gives the model of the decision slot, next to the models of the
other slots.

## The `decide` span

Each batch of questions that a session sends to the model opens one span named
`FoundationModelsRouter.decide`, of kind `client`. Without a tracer bootstrap,
the tracer is a no-op tracer. A prewarm opens no span.

The span has three attributes. Their names are stable API:

| Attribute | Value |
|---|---|
| `router.id` | The recording root id of the router that resolved the model. |
| `model.ref` | The chosen model reference, in canonical string form. |
| `decision.question_count` | The number of questions in the batch. |

The span never holds the state text, the question text, the option text or an
answer value. When the model throws an error, the span gets the error status
and the attribute `error.type`, which is the type of the error. The span never
holds the description of the error.

## The integration test

`IntegrationTests/Tests/FoundationModelsRouterIntegrationTests/DecisionSlotIntegrationTests.swift`
tests the slot with real models on Metal:

- The decision model is `decider-2b` (`Mapika/decider-2b-GGUF`,
  `decider-2b-v12-Q4_K_M.gguf`, about 1.3 GB), at the revision of the Metal
  reference of the `FoundationModelsDecision` package. The model wins the slot,
  and its answers agree with the reference, with a tolerance of 0.005.
- A profile with no decision candidate decides on its `flash` model.
- A fallback decision and a `flash` generation run at the same time, and both
  finish.

Run only this suite:

```sh
swift test --package-path IntegrationTests --filter DecisionSlotIntegrationTests
```

The first run downloads about 1.3 GB for the decision model.
