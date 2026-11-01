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

`LiveModelLoader` loads each model through the Extras `HubModelLoader`. For an
embedding model, `HubModelLoader` looks at the files of the repository with
the rule in the section "How the router detects a Core ML model". A Core ML
repository loads with the Extras Core ML loader, and the model runs on the
ANE. Any other repository loads with MLX. A generation model always loads with MLX, because Core ML
loads embedding models only.

A host that gives a cache folder or a token provider to `LiveModelLoader`
gives it to both loaders.

The router gives the model to your tools through the same `.embedding` slot of
the profile as other embedding models. `RoutedEmbedder.embed(texts:)` works
the same way, and its span keeps the attributes `model.ref` and
`embedding.dimension`.

## How the router detects a Core ML model

The router uses the rule of Extras: `HubModelFormat.detect(paths:)`. The
router gives it the paths of the files of the repository, relative to the
root. The router gets these paths from the repository metadata, during sizing
and before any download. The rule has two parts:

- A repository is a Core ML repository when it has a `.mlpackage` folder and
  no file that ends in `.safetensors`, at any depth.
- Any other repository is an MLX repository.

A repository with only a `.mlmodelc` folder is an MLX repository. The Extras
Core ML loader compiles a `.mlpackage` folder itself, and it does not load a
compiled `.mlmodelc` folder. A repository with a `.mlpackage` folder and a
`.safetensors` file in a sub-folder is also an MLX repository.

The router sizes a Core ML repository by its largest `.mlpackage` folder. It
does not size a `.mlmodelc` folder. `RepoMetadata.isCoreMLEmbedding` reports
the result.

The router uses the result for one rule: a Core ML model cannot fill the
standard slot or the flash slot. When a profile lists such a model for one of
these slots, resolution rejects the candidate with a clear message, and
tries the next candidate. The message names the model and the rule.

The router does not choose the loader from this result. `HubModelLoader`
chooses the loader from the files of the repository with the same rule, so
the router and the loader cannot disagree.

## Prefixes

The model needs a prefix in front of each text. The Core ML loader adds no
prefix, so the router adds it:

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
