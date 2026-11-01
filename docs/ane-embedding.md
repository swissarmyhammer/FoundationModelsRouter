# ANE embedding models

The Apple Neural Engine (ANE) is the machine-learning chip in Apple silicon.
A CoreML model can run on the ANE. An ANE model uses less power than the same
model on the GPU, and it leaves the GPU free for the language models.

## The default embedding model

The default embedding model is `erjigit17/embeddinggemma-300m-ane-coreml`.
It is a CoreML build of the EmbeddingGemma 300M model for the ANE. It gives
vectors of 768 values. The vectors are normalized already.

## How you choose an embedding model

The embedding slot of `ProfileDefinition` lists `ModelRef` candidates. Put an
ANE CoreML model in that list in the same way as any other embedding model.
The router does not need a special flag from you.

## How the router loads it

A CoreML embedding model loads through a new Extras container. That container
runs the model on the ANE. The router gives the model to your tools through
the same `.embedding` slot of the profile as other embedding models.

## How the router detects a CoreML model

The router detects a CoreML repository from the repository metadata.

Status: planned. This detection is not in the code yet. Until it is, do not
depend on automatic selection of the Extras container.

## Prefixes

The model needs a prefix in front of each text. The loader adds no prefix, so
the router adds it:

| Call | Prefix |
|---|---|
| `embed(queries:)` | `task: search result \| query: ` |
| `embed(documents:)` | `title: none \| text: ` |
| `embed(texts:)` | none |

A model with no entry in the prefix table gets no prefix from any of the three
calls. The table is in `EmbeddingPrefix.swift`. To support a new model, add one
entry to the table.

## The 128 token limit

The model reads 128 tokens. It cuts a longer text with no error and keeps the
end token. The prefix uses some of the 128 tokens, so a query or a document
has fewer than 128 tokens for its own text.

The router has no token counter for an embedding model. Thus the router cannot
tell a caller that a text is too long. To stay inside the limit, split a long
document into short parts before you call `embed(documents:)`.
