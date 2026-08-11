---
assignees:
- claude-code
position_column: todo
position_ordinal: 9a80
title: Define and test the recording durability policy
---
## Problem

The JSONL recorder appends through cached `FileHandle`s (Sources/FoundationModelsRouter/Recording/Sinks.swift:29-31) and never syncs. The crash story is undefined and untested:

1. A power cut or a kill can tear the final line of `transcript.jsonl`. That torn tail is the EXPECTED crash artifact — yet today one bad byte fails the entire tree load with a raw `DecodingError` that names no file (Sources/FoundationModelsRouter/Recording/TranscriptTree.swift:429-431).
2. No flush or sync policy exists, so the window between "the turn completed" and "the record is durable" is whatever the OS decides.
3. The "lost run" tests never test durability: they close a router cleanly and reopen it; no write is ever interrupted.

## Proposed solution

1. Define the write policy and document it on the recorder: each appended line is written in one `write` call (already true — one line per append), and the handle is synced at a defined point. Decide the sync point: per append (safest, slowest), per turn close (the natural unit), or on a short timer. Recommend per turn close.
2. Tolerate the torn tail on load: when the LAST line of a `transcript.jsonl` fails to decode, drop it, log a warning naming the file and byte offset, and continue. A torn line is the crash artifact the policy expects.
3. Fail typed on mid-file corruption: a bad line that is NOT the last one throws a `TranscriptTreeError` naming the session and file (coordinates with task ^xky3j8w item 6 — that task adds the error context; this one adds the tail-tolerance policy).
4. Tests: write a valid log, truncate the final line at several byte offsets, and assert the tree loads with the turn-before state; corrupt a mid-file line and assert the typed error.

## Acceptance

- A truncated final line never fails a tree load; the loss is one event, reported in a warning.
- A corrupt mid-file line fails loudly with the session id and file path.
- The sync point is documented on `JSONLRecorder` and exercised by a test that kills nothing but asserts the sync call happens at the documented point. #transcript