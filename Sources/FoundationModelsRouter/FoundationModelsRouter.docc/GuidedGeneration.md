# Guided generation

Constrain a turn to a JSON Schema the caller supplies at run time, and read the
answer back as data (task ^jp93e7c).

## Overview

A guided call gives the model a grammar as well as a prompt. The model can
answer only inside that grammar, so the caller reads the answer as data instead
of parsing free text and repairing what the model wrote.

Use ``RoutedModel/respond(to:matching:maxTokens:)`` when the shape arrives at
run time — from a tool manifest, a configuration file, or the user — so there is
no Swift type to decode into. The method takes the JSON Schema source, runs one
constrained turn, and parses the output into a ``JSONValue``:

```swift
let profile = try await router.resolve(profile: definition, reporting: progress)
let value = try await profile.standard.respond(
    to: "Name one color.",
    matching: #"{"type":"object","properties":{"name":{"type":"string"}}}"#)

guard case .object(let fields) = value, case .string(let name)? = fields["name"] else {
    return
}
print(name)
```

Hold the resolved ``LanguageModelProfile`` for as long as the call runs. A slot
handle holds its profile weakly.

To constrain every turn of a conversation rather than one turn, vend a session
with ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``.
The session carries its ``Grammar`` for its whole life, and a fork inherits it.

## The supported schema subset

xgrammar accepts a subset of JSON Schema. `$ref`, `allOf` and `format` are
outside that subset. A schema that uses one of them is rejected before the model
runs, so a rejected schema costs no tokens.

Every failure of the guided path is a ``GuidedRequestError``, which a caller
catches by type:

- ``GuidedRequestError/unsupportedSchemaConstructs(_:)`` — the schema used one
  or more keywords outside the subset. The value lists them, sorted.
- ``GuidedRequestError/invalidJSONSchema(_:)`` — the schema source did not parse
  as JSON.
- ``GuidedRequestError/emptyGrammar`` — the schema source was empty.
- ``GuidedRequestError/decodingFailed(_:)`` — the model's output did not parse.
  The value is the raw output.
- ``GuidedRequestError/ebnfNotSupportedByLanguageModelSession`` — a
  ``Grammar/ebnf(_:)`` grammar reached a backend that accepts a schema only.

## Topics

### Constrained generation

- ``RoutedModel/respond(to:matching:maxTokens:)``
- ``RoutedModel/makeGuidedSession(grammar:instructions:workingDirectory:tools:budget:compactionPrompt:summarization:agentSpawn:discoveryPriming:)``

### The grammar and the result

- ``Grammar``
- ``JSONValue``

### Failures

- ``GuidedRequestError``
