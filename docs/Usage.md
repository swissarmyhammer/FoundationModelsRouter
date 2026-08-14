# Using RoutedSession

Two surfaces, one session. `respond(to:)` blocks and returns the answer.
`streamEvents(to:)` delivers the same turn incrementally. Both run the same
turn machinery. They differ in who is listening — and in what each one waits
for: `respond(to:)` also drains the run plane before it returns, while
`streamEvents(to:)` leaves backgrounded work running (see below).

Every transcript and every line of output below was **captured by running the
code**, against the deterministic scripted model so the values are stable.
Nothing here is illustrative or hand-written.

---

## 1. `respond(to:)` — blocking

Use this for tests, and for sub-model calls such as rules evaluation and
embeddings: short, single-turn, no tools, nothing to stream.

```swift
let answer = try await session.respond(to: "what is the vault code?")
print("answer: \(answer)")
```

Captured output:

```
answer: answer: NO-TOOL-OUTPUTS
```

(The mock model composes its answer as `answerPrefix` + the tool outputs it
saw. With no tools mounted it emits `NO-TOOL-OUTPUTS`, so the doubled word
`answer:` is the prefix, not a typo.)

The transcript after that turn — two entries:

```
entryCount=2
  (Prompt)   what is the vault code?
  (Response) answer: NO-TOOL-OUTPUTS
```

`respond` returns the SDK's final answer verbatim. It derives **no events** —
the sink is `nil` on this path.

It also drains the **run plane** before it returns. When a tool call of the
turn backgrounds its work and hands the model a completion token, `respond`
waits for every such run to settle and runs a further turn with those results,
so the answer is written from what the work returned rather than from the
token, and nothing is left parked when the call returns. The caller never has
to make the model poll a `wait` tool. The drain is bounded: it runs at most
four further turns, so a model that keeps starting work from inside a drained
turn is answered early rather than awaited forever. A cancelled turn is not
drained.

A cancellation also ends a drain that is already waiting — `cancelCurrentTurn()`
reports `.requested` for such a call, and cancelling the caller's own task works
too. The call then returns its last turn's answer rather than throwing, and the
runs it was waiting on stay parked: stopping them is `close()`'s job.

---

## 2. `streamEvents(to:)` — incremental

Use this for an interactive client.

This surface does **not** drain the run plane: it finishes while the work a
tool of the turn backgrounded is still running. That is the feature here — an
interactive client watches the run plane itself and folds each result in as it
arrives.

```swift
for try await event in await session.streamEvents(to: "what is the vault code?") {
    print("event: \(event)")
}
```

Captured output:

```
event: textDelta("answer: NO-TOOL-OUTPUTS")
event: turnEnded(TokenUsage(tokensIn: 0, tokensOut: 1, contextFill: 0.0001220703125))
```

The transcript after the streamed turn is **identical** to the blocking one —
same entries, same order. That is the parity the surfaces owe you:

```
entryCount=2
  (Prompt)   what is the vault code?
  (Response) answer: NO-TOOL-OUTPUTS
```

Events are **derived from the transcript delta**, not from a separate
conversation: `recordTranscriptDelta` switches over the entries a turn appended
and synthesises `SessionEvent`s from them. Streaming is a projection of the
transcript.

Two things a client must know:

- **The stream is turn-scoped.** `streamEvents(to:)` delivers events for the
  turn it started and nothing else. It will not show you another turn's events,
  and it will not show you a detached tool run completing from an earlier turn.
  The one session-wide channel, `streamSessionEvents()`, currently carries a
  single event type (`discoveryPrimingFailed`).
- **Abandoning the stream cancels the turn behind it.**

---

## 3. Queued prompts — enqueue, inspect, cancel, edit

A user can type ahead. Prompts queue in FIFO order, each with a stable id, and
a queued prompt can be cancelled or rewritten until it is dispatched.

```swift
let first  = await session.enqueue(prompt: "what is the vault code?")
let second = await session.enqueue(prompt: "and the door code?")
let third  = await session.enqueue(prompt: "typo hree")

for (id, prompt) in await session.pendingPrompts() {
    print("pending \(id): \(prompt)")
}

await session.cancel(id: second)
await session.replace(
    id: third,
    prompt: Transcript.Prompt(segments: [.text(.init(content: "typo here, corrected"))]))

let answer = try await session.dispatchNextPrompt()
```

Captured output:

```
enqueued 3 prompts
  pending 01KZQDF60EC84SR4BVKR0BRMD7: (Prompt) what is the vault code?
  pending 01KZQDF60ENH6YS0QV2GN0MRCY: (Prompt) and the door code?
  pending 01KZQDF60EDW5HJXKTG51ANT13: (Prompt) typo hree
cancel(second) -> applied
replace(third) -> applied
after edits:
  pending 01KZQDF60EC84SR4BVKR0BRMD7: (Prompt) what is the vault code?
  pending 01KZQDF60EDW5HJXKTG51ANT13: (Prompt) typo here, corrected
dispatchNextPrompt -> answer: NO-TOOL-OUTPUTS
remaining: 1
```

Note the second prompt is gone and the third's text is rewritten, both by id,
with order preserved.

### The queue does not drain itself

`dispatchNextPrompt()` is a **pull**. Nothing runs it for you — an automatic
drain is a recorded non-goal. The app owns the loop:

```swift
while let answer = try await session.dispatchNextPrompt() {
    render(answer)
}
```

### Two submission paths, and they do not interleave

`enqueue` + `dispatchNextPrompt` is the queue. `respond`/`streamEvents` is the
direct path, and it **deliberately bypasses the queue** — an ad hoc turn never
dequeues a waiting prompt. Mixing both gives you two independent orderings.
Pick one per session.

### What `cancel` cannot reach

`cancel(id:)` only affects a prompt that is still queued; once dispatched it
returns `.alreadySent`. There is a window — after the prompt is drained but
before its turn begins generating — where `cancel(id:)` returns `.alreadySent`
and `cancelCurrentTurn()` returns `.noTurnInFlight`, so neither works. That gap
is tracked on `^way106d`.

To stop a turn that is already running, use `cancelCurrentTurn()`.

---

## Known gaps

Stated plainly so nobody builds on sand:

- **A real tool-using turn is not yet correct.** The two surfaces still
  disagree on the transcript and the answer against a live model, and the tool's
  data does not reliably reach the final answer. Tracked on `^w8dzvee`; the
  scripted path is correct and the gated comparison is what fails.
- **Detached tool runs have no path back into the transcript.** A long-running
  tool that parks and later completes returns as plain text folded into the
  *next* turn's prompt — so the transcript never records it as a tool result and
  a transcript-rendering UI has nothing to draw. Tracked on `^zn8n9md`.
- **Events carry no turn or prompt id**, so a client cannot correlate
  `prompt → turn → events`. Tracked on `^way106d`.
