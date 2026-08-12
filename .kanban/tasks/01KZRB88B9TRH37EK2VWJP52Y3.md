---
assignees:
- claude-code
comments:
- actor: claude-code
  id: 01kzthws0cwb19wgsa63spfc22
  text: |-
    Research and design decisions.

    1. Where "open time" is. `Router.init` and `JSONLRecorder.init` are public and do not throw. A change to `throws` on them breaks the public API. The rule for this task is: additive only. Thus the typed error gets a new, additive chokepoint: a new public throwing initializer `JSONLRecorder(owningDirectory:now:)`. It takes ownership of the root at construction. The error type is `RecordingRootLockError.alreadyOwned(root:owner:)`. It names the owner process id and the time of acquisition.

    2. The default, non-throwing path stays safe. `JSONLRecorder(directory:)` (the recorder `Router.init` makes from `recordingsDir`) takes ownership of its root before the first append. This keeps the current contract: no file is written before the first append. If a different live writer owns the root, the recorder drops each event and writes a log message that names the owner. No line is written, so no interleave and no corruption can occur. The recorder tries again on each append, so it can take the root after the owner releases it.

    3. Two guard layers, as the card asks. (a) A process-wide registry, with a canonical (symlink-resolved, standardized) root path as the key. This catches a second recorder in the same process. (b) A lock marker file `owner.lock` in the root. Its JSON payload is a `RecordingRootOwner` (process id + acquisition time). The file is created with `open(O_CREAT|O_EXCL)`, which is atomic. This catches a writer in a different process.

    4. Stale lock. A marker is stale when: the process id is not alive (`kill(pid, 0)` gives ESRCH), or the marker holds this process's own pid while the in-process registry has no claim (a leftover), or the payload does not decode (a torn file). Takeover of a stale marker writes a warning to the log, then removes and re-creates the marker. If a different process re-creates the marker in that window, the result is the typed error `RecordingRootLockError.contested(root:)`.

    5. Clean shutdown. The ownership claim is a token object held by the recorder. Its `deinit` removes the marker file and the registry entry. Thus release occurs when the recorder deallocates. No new public close method is necessary.

    6. Scope. The lock guards the recorder's own root directory. A per-session `recordingRoot` override points to a different tree; that tree is out of this card's scope. `InMemoryRecorder` and `NoneRecorder` take no lock. Read paths (restore, `TranscriptTree.load`, `MergedTranscript.merged`) take no lock. Discovery matches files by exact name, so `owner.lock` does not disturb restore.
  timestamp: 2026-08-12T08:37:17.452362+00:00
- actor: claude-code
  id: 01kztk06qv3w4s2h4vxh5c0pt6
  text: |-
    Implementation landed, TDD (RED first, then GREEN).

    What went in:

    - New file `Sources/FoundationModelsRouter/Recording/RecordingRootLock.swift`: the public `RecordingRootOwner` payload (process id + acquisition time), the public typed `RecordingRootLockError` (`alreadyOwned(root:owner:)` and `contested(root:)`), the public marker-name constant `recordingRootLockFileName` (`owner.lock`), the internal process-wide `RecordingRootRegistry` (NSLock-guarded; a lock and not an actor because release runs from a synchronous `deinit`), and the internal RAII token `RecordingRootOwnership` (acquire = registry claim + `open(O_CREAT|O_EXCL)` marker; `deinit` = marker removal + registry release).
    - `Sinks.swift`: `JSONLRecorder` got a new public throwing `init(owningDirectory:now:)` (the open-time chokepoint), a `rootOwnership` stored claim, a lazy per-append `ensureRootOwnership()` guard on the existing non-throwing path (refused appends drop with a log, before `seq` is stamped, and acquisition retries on each append), and the internal init got an additive `rootOwnership` parameter. The extracted `productionOpenHandle` removes the duplicated opener closure.
    - New tests `Tests/FoundationModelsRouterTests/RecordingRootLockTests.swift` (6 tests): second owning recorder throws with the owner's pid; a lazy first writer blocks a later owner; a second non-owning writer drops and does not interleave (root file holds only seq 0,1 from writer one); a dead-pid stale marker is taken over and rewritten; a torn marker is taken over; clean shutdown (deallocation) removes the marker and a successor acquires.

    Test adjustments the guard required:

    - `SessionTreeRestorationTests` and `SessionTreeRestorationLostRunTests` simulate "a fresh process continues the root" with a second (and third) live router in the same process, and those continuation routers WRITE. Under the guard, that is precisely the forbidden second live writer, so those tests' appends dropped. Fix: `makeRouter` in both files got an additive `recorder:` parameter, and the two affected tests share the first writer's recorder across the simulated phases. All other restoration tests only read after the first phase and needed no change.

    RED observed: the new test file failed to compile with "cannot find recordingRootLockFileName", "extra argument owningDirectory", "cannot find RecordingRootOwner" (command 32). GREEN: the new suite passed 6/6 (command 34), then the full suite passed (command 36).
  timestamp: 2026-08-12T08:56:38.395881+00:00
- actor: claude-code
  id: 01kztk0fx7tp4gwmmccykwz3p3
  text: |-
    ### implement — changed
    - evidence: 5 files — Sources/FoundationModelsRouter/Recording/RecordingRootLock.swift (new), Sources/FoundationModelsRouter/Recording/Sinks.swift, Tests/FoundationModelsRouterTests/RecordingRootLockTests.swift (new), Tests/FoundationModelsRouterTests/SessionTreeRestorationTests.swift, Tests/FoundationModelsRouterTests/SessionTreeRestorationLostRunTests.swift. Final `swift test`: 870 + 27 + 24 tests passed, 0 failures, 0 warnings, 1 known issue (accepted BoundedWait).
    - next: /review
  timestamp: 2026-08-12T08:56:47.783860+00:00
position_column: doing
position_ordinal: '8180'
title: Guard a recording root against a second writer
---
## Problem

Nothing stops two `Router` instances — in one process or in two processes — from appending to the same recording root. `seq` is an in-memory counter per recorder (Sources/FoundationModelsRouter/Recording/Sinks.swift:87), so a second writer restarts the sequence and interleaves its lines into the same files. The total order corrupts silently: no error, no warning, and the corruption is only discovered (if ever) at restore time. The concurrent-writer case is also explicitly untested (noted in the restoration audit).

## Proposed solution

1. Take ownership of a recording root at first write: create a lock marker (a lock file with the owner's process id and a timestamp, or an `flock` on a well-known file — decide per platform behavior on macOS).
2. A second router that opens the same root gets a typed error naming the current owner. Do not silently share, and do not silently steal.
3. Handle the stale lock: an owner process that died leaves a marker behind. Detect staleness (the pid no longer runs) and take over with a logged warning.
4. Release the lock on clean shutdown.
5. Tests: second in-process router on the same root throws; stale-lock takeover succeeds with a warning; clean shutdown releases.

## Acceptance

- Two live routers can never both write one recording root.
- The failure is a typed error at open time, not corruption at restore time.
- A crashed owner does not permanently brick its recording root. #transcript