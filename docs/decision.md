# Decisions

A resolved profile has four slots: `standard`, `flash`, `embedding` and
`decision`. The `decision` slot answers questions about a state with
probabilities. It gets the probabilities from the model. It generates no text.

## The slot

- The slot is `ModelSlot.decision`. Its wire form is `"decision"`.
- The handle is `profile.decision`, of type `RoutedDecider`
  (`RoutedModel<any LoadedDecisionContainer>`).
- The pool role of the slot is `ModelRole.llm`. A decision model is an LLM.
  Its log probabilities, or the decision code of llama.cpp, give the answers.
  Thus a decision model and a generation model of the same pool key are one
  resident model.
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
h2oai/h2o-lightning-4b-gguf/h2o-lightning-4b-Q4_K_M.gguf@61f8d8b7a8c2d84426d0d143ca187f65d235934b
```

This is the `h2o-lightning-4b` model, quantized to `Q4_K_M`, in GGUF format,
at a pinned revision. The GGUF file has the decision type `h2o-lightning`, thus
the decision slot takes the native decision path (see the next section). An
empty list fails the resolve: the slot is required.

## The context of the slot

The decision slot has a context of its own: `ProfileDefinition.decisionContext`,
in tokens. Its default is `ProfileDefinition.defaultDecisionContext`, 16,384
tokens. Set it in the initializer, or on the property:

```swift
let profile = ProfileDefinition(
    name: "coding",
    description: "Code agent with a short decision state.",
    standard: ["mlx-community/Qwen3-14B-4bit"],
    flash: ["mlx-community/Qwen3-1.7B-4bit"],
    embedding: ["mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ"],
    decisionContext: 8_192
)
```

The router sizes the decision model at this context, asks the pool for it at
this context, and loads it at this context. It does not use the working
context (`context`) of the other slots. A decision state is usually small, and
a GGUF decision model allocates its whole KV cache when it loads, so the
working context would take memory from the `standard` window for nothing. The
host builds each `DecisionState`, so the host chooses the bound on its size.

The resolve reports the context:

- `profile.decision.resolution.contextTokens`, and
  `ResolutionProgress.slots[.decision]?.contextTokens`;
- the `context.decision_tokens` attribute of the `FoundationModelsRouter.resolve`
  span, beside `context.tokens`, the working context;
- the `decisionContext` field of the resolved profile in the `index.md` record
  of a root session.

## The decision path

The router selects the decision path of the chosen model in this order:

| The model | The decision path |
|---|---|
| 1. A GGUF model whose `<arch>.decision.type` llama.cpp supports | The native path: the decision code of llama.cpp makes the prompt and reads the answer. The router uses `PooledNativeDecisionModel`. |
| 2. Else, the repository root has a `decider_config.json` file | `DeciderPromptFormat`, with the configuration of that file |
| 3. Else | `GenericPromptFormat`, which works with any instruct model |

Thus you can add a decision model with only the reference of a GGUF file, the
same as an LLM. The model needs no Swift prompt format.

The sizing step reads `<arch>.decision.type` from the GGUF header, in the same
read as the other sizing values (for example `qwen35.decision.type =
"h2o-lightning"` for `h2o-lightning-4b`). Only `FoundationModelsLlamaCpp` tells
which decision types llama.cpp supports (`LlamaDecisionType` and its
`isSupportedByDecide`). The router keeps no list of types. A type that
llama.cpp does not know, or a type that reads an image, goes to step 2.

An MLX model has no GGUF header, thus it uses only steps 2 and 3.

On the native path, the router asks the model with no checks of its own. An
error of the decision code of llama.cpp comes to the caller unchanged, for
example `LlamaError.decisionRequestNotValid(reason:)` for a question with more
options than the model accepts.

The router reads `decider_config.json` through the metadata source of the
sizing step, at the revision of the model reference. A local folder records the
file at its top, as a Hub repository does.

When the router cannot read the prompt format of the chosen candidate (for
example, `decider_config.json` is not valid), the resolve fails with
`DecisionFormatFailure`, which names the model and the error of the read.

`GenericPromptFormat` turns reasoning off in the chat template. Some chat
templates ignore this request and leave a thinking block open (`<think>` or
`<|channel>thought`). A thinking block before the answer gives incorrect
probabilities. Thus the format does not close the block. It throws
`DecisionError.unsupportedModel` at the first question.

## The memory rule

The decision slot is required, as each other slot is. It never uses the model
of another slot in place of its own candidates.

1. The four slots (`embedding`, `standard`, `flash` and `decision`) are fitted
   together, in that order, against one budget. The decision slot is sized at
   `decisionContext`, and the other slots at the working context.
2. When the profile names no context, the window search sizes the four slots
   together. Thus the decision model gets its bytes first, and the window is
   smaller by them. The decision charge does not grow with the window, so
   each token of the window goes to the other slots.
3. The slot tries each decision candidate in preference order. The first
   candidate that fits wins.
4. A candidate that is the model of the `embedding`, `standard` or `flash`
   slot, under a pool key that serves the decision context, is the same
   resident model. It costs 0 more bytes. An MLX model keeps no context in the
   pool, so it serves any decision context. A GGUF model loads at a fixed
   context, so it serves a decision context up to its own: a GGUF `flash`
   model at a 100,000-token window serves a 16,384-token decision slot.
5. When no decision candidate fits, at the smallest window too, the resolve
   fails with `ResolutionFailure`. Its description names each slot, each
   candidate, its footprint and its verdict.

### The rejections in the resolution

The resolution of the slot records why each candidate was rejected. Code in
this package and in its test targets reads it from
`profile.decision.resolution`, which has `package` access:

- `considered` holds one `CandidateReport` for each decision candidate, in
  preference order. Its `verdict` tells the result:

| Verdict | Meaning |
|---|---|
| `chosen` | The candidate fits, and the slot uses it. |
| `tooLarge` | The candidate needs more bytes than the other slots left. |
| `skippedHigherPreferenceChosen` | A candidate earlier in the list won. The router did not size this one. |
| `metadataUnavailable(reason)` | The router could not size the candidate, or could not read its prompt format. `reason` tells why. |

`ResolutionProgress.slots[.decision]?.chosen` gives the model of the slot
during the resolve.

### A model that cannot answer on its path

If the model of the slot cannot answer on its decision path, the resolve does
not fail. The first decision of a session throws the error:

- `PooledLogitsModelError.notLogitsCapable` for a prompt format, when the
  model gives no log probabilities.
- `PooledDecisionsModelError.notDecisionCapable` for the native path, when the
  model cannot answer decision questions natively.

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
