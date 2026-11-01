# ANE embedding models

The Apple Neural Engine (ANE) is the machine-learning chip in Apple silicon.
A CoreML model can run on the ANE. An ANE model uses less power than the same
model on the GPU, and it leaves the GPU free for the language models.

## The default embedding model

The default embedding model is `erjigit17/embeddinggemma-300m-ane-coreml`.
It is a CoreML build of the EmbeddingGemma 300M model for the ANE.

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
