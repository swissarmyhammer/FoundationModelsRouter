# The checked-in compaction recording

This directory holds one recorded conversation, exactly as the router wrote it.
`RecordedTranscriptCompactionIntegrationTests` reads it back into a
`FoundationModels.Transcript` and folds it. Nothing else reads it.

## Why a recording, and not a transcript written in Swift

Task `^pfdrppj`. A transcript written in Swift is one more thing that has to be
kept true, and it went untrue twice in one week: `^vjf3mdm` sized 24 seeds too
small for a real summary to shrink them, and `^wnj3ka3` sat a round-trip fixture
below its own trigger. Both were sized against an estimate rather than against a
measurement.

A recording has neither failure mode. It carries the entry kinds a hand-written
fixture forgets, and it is inert: no later edit can shrink it by accident,
because nothing in Swift describes its size.

## Why it is checked in, rather than read live off the box

This was forced, not preferred.

The package has no ambient recordings root. `Router` takes its `recordingsDir`
as a parameter; no default path and no environment variable names one, and every
other test in the package records into a fresh temporary directory it removes
afterwards. A test that read "whatever recording is on this box" would find
nothing on any box, so it would skip everywhere and prove nothing.

## The layout

    <sessionId>/session.json       the write-once SessionSidecar
    <sessionId>/transcript.jsonl   the append-only event stream

**This directory plays the recording root.** `TranscriptTree.load(under:)` reads
a session's id from its own directory name and its parent from the directory it
nests under, and it requires a root session to sit DIRECTLY under the root it is
given. So the session directory sits here, which is the same shape the router
writes for a session vended with a per-session `recordingRoot:`.

Neither recorded file was edited. Both are byte-for-byte what the router wrote.
The recording run's own router id is not a path segment here, but it is not lost
either: `session.json` carries it as `routerId`.

Nothing in Swift names the session id. The test reads it off the loaded tree.

## What the recording holds

31 recorded events, reconstructing to a 30-entry transcript that carries every
entry kind real traffic has: an `instructions` header with two tool definitions,
`prompt` entries, `response` entries, `reasoning` entries, `toolCalls` entries
and `toolOutput` entries. The test asserts each kind is present, so a fixture
that silently lost one goes red rather than folding something simpler than it
claims to.

The transcript estimates 4297 tokens, of which the folded span is 2366. That
span is past `Summarization.maxChunkTokens` (2000), so the stage chunks it and
the fold costs three summarizer calls rather than one — the map-reduce path no
other fast suite reaches.

## How it was made

Recorded on 2026-08-18, on an Apple silicon box, by driving one
`RoutedSession` through six scripted turns and keeping what the router wrote.

| what | value |
|---|---|
| model | `mlx-community/Muse-Glimmer-30B-4bit` (`RealModels.standard`) |
| working context | 8192 (`RealModels.context`) |
| decoding | argmax (`GenerationOptions.SamplingMode.greedy`) |
| reply ceiling per turn | 900 tokens |
| tools mounted | `lookup-alpha`, `lookup-beta`, each returning `MARKER-7F3A-<step>` |
| schema version | 2 |
| wall clock | 253 s |

The conversation is a synthetic engineering discussion — an ingest-path
replacement for a "station archive" and its migration plan — written for this
fixture. Two turns carry long prose, one turn asks the model to call a tool, and
three short turns follow. The long turns are what put the folded span past the
point where `Summarization.minimumSummaryTokens` stops binding; the short turns
are the recency window.

The model's own replies, its reasoning, its tool calls and the tool outputs are
whatever the model produced. Nothing was written by hand into the recording.

### The two settings chosen at record time to keep operator paths out

Both were set before recording rather than edited out afterwards, because
editing a recording is the hand-maintenance this fixture exists to avoid.

- **`workingDirectory`** was set explicitly to `/recordings/station-archive`. A
  session defaults its working directory to its own recording directory, which
  at record time was an absolute path on the recording machine.
- **`recordingRoot` was left unset**, so the session took the router-level
  layout. The per-session `recordingRoot:` override is stamped into
  `session.json` as `configuration.recordingRoot`, and that value is an absolute
  path on the recording machine.

## Redaction review

Every byte of both files was reviewed before they were committed. What was
searched for, and what was found:

| looked for | found |
|---|---|
| the operator's user name, home directory, or any `/Users/...` path | none |
| any path from the recording machine — temporary directories, the repository path, the session directory | none |
| the Hugging Face cache path, or any model path on disk | none |
| API keys and token shapes (`sk-`, `pk_`, `api_key`, `Bearer`, `AKIA`) | none |
| PEM or SSH private key blocks | none |
| passwords, credentials, connection strings | none |
| URLs, hostnames, webhook targets | none |
| private prose — anything a person wrote about anything real | none; every prompt is synthetic and is reproduced in this file's own recipe |

One search hit needs stating so a later reader does not re-raise it. The word
`secret` appears once in `session.json`, inside
`configuration.compactionPrompt.text`. That is the router's own default
compaction prompt — the line "Preserve safety- or security-relevant instructions
VERBATIM (files or data to avoid, operations not to perform, secret handling)".
It is product text, checked into `Sources/` already, and it is not a credential.

## Re-recording it

Nothing in the test needs editing if this fixture is replaced: no identifier, no
size and no count is written down in Swift. Delete this directory's recording,
record a new conversation with the settings in the table above, put it back in
the same layout, and re-run the redaction review in this file before committing
it.
