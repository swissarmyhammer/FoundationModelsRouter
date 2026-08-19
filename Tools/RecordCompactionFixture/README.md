# RecordCompactionFixture

Records the checked-in compaction fixture again (task `^4bb3mjv`). The fixture
lives at `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/`,
and its own `README.md` states what the recording is and why it is checked in.
This tool is HOW to make a new one: the recipe is code here, not prose there.

## Run it

    swift run RecordCompactionFixture [output-directory]

Needs Apple silicon. The first run downloads the 30B model. The recording
itself took 253 s of wall clock with the weights already cached.

The tool writes into a fresh directory — the named one, or
`CompactionRecording-<ULID>` under the working directory — and refuses a
directory that already exists, so it can never overwrite the checked-in
fixture.

## What one run does

1. Resolves `mlx-community/Muse-Glimmer-30B-4bit` at context 8192 with argmax
   decoding, and opens one recorded `RoutedSession` with the two lookup tools
   mounted. The two redaction settings are applied here in code:
   `workingDirectory` is the synthetic `/recordings/station-archive`, and the
   `recordingRoot:` override stays unset. `RecordingScript.swift` states why.
2. Drives the six scripted turns in `RecordingScript.swift`, each under a
   900-token reply ceiling.
3. Flattens the recorded layout to the fixture's shape: the session directory
   sits directly under the output directory, as it sits under the fixture
   directory.
4. Reads the recording back and verifies it carries every entry kind real
   traffic has. A recording that lost a kind fails here, before anybody
   commits it.
5. Runs `RecordingRedactionScan` over the recorded bytes — the fixed
   forbidden patterns plus this machine's own user name and directories. A
   finding fails the run and names the file, the line and the pattern.
6. Prints where the verified recording is, and the copy step that replaces
   the checked-in fixture.
