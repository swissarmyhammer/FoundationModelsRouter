import Foundation
import FoundationModels
import FoundationModelsRouter
import FoundationModelsRouterTestSupport
import HuggingFace
import MLXHuggingFace
import MLXLMCommon
import Tokenizers

/// # RecordCompactionFixture: records the checked-in compaction fixture again
///
/// The recording under
/// `Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/`
/// carries `RecordingSchemaVersion` 2. When a schema bump makes the router
/// refuse it, somebody must record a new one — and the way to do that is this
/// tool, not a paragraph (task `^4bb3mjv`). Run it with:
///
///     swift run RecordCompactionFixture [output-directory]
///
/// The tool drives one `RoutedSession` through the six scripted turns in
/// `RecordingScript.swift`, keeps what the router wrote, verifies the
/// recording carries every entry kind real traffic has, and runs
/// `RecordingRedactionScan` over the recorded bytes. It writes into a FRESH
/// directory — the named one, or `CompactionRecording-<ULID>` under the
/// working directory — and refuses a directory that already exists, so it
/// can never overwrite the checked-in fixture. A person copies the verified
/// session directory into the fixture directory; the closing printout states
/// the exact step.
///
/// It needs Apple silicon, and it downloads the 30B model on first run. The
/// original recording took 253 s of wall clock with the weights already
/// cached.

// MARK: - Failure exit

/// Writes `message` to standard error and stops the run with a failure exit.
///
/// - Parameter message: What went wrong, stated for the operator.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(EXIT_FAILURE)
}

// MARK: - Reading the recorded layout

/// Returns the single subdirectory of `directory`.
///
/// The recorded layout nests one router directory holding one session
/// directory, so each level must hold exactly one entry; any other count
/// means the recording did not land the way this tool wrote it.
///
/// - Parameters:
///   - directory: The directory to read.
///   - role: What the one subdirectory is, for the failure message.
/// - Returns: The one subdirectory.
func onlySubdirectory(of directory: URL, holding role: String) -> URL {
    guard
        let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])
    else {
        fail("cannot read \(directory.path) while looking for the \(role)")
    }
    let subdirectories = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    guard subdirectories.count == 1, let only = subdirectories.first else {
        fail("expected exactly one \(role) under \(directory.path), found \(subdirectories.map(\.lastPathComponent))")
    }
    return only
}

/// Every recorded file under `directory`, at any depth: the sidecar
/// (`.json`) and the event stream (`.jsonl`).
///
/// - Parameter directory: The directory holding the finished recording.
/// - Returns: The recorded files, sorted by path.
func recordedFiles(under directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        fail("cannot enumerate the finished recording at \(directory.path)")
    }
    return enumerator
        .compactMap { $0 as? URL }
        .filter { ["json", "jsonl"].contains($0.pathExtension) }
        .sorted { $0.path < $1.path }
}

// MARK: - The output directory

/// Where the finished recording goes: the one command-line argument, or a
/// fresh `CompactionRecording-<ULID>` under the working directory.
let outputDirectory: URL = {
    if let namedPath = CommandLine.arguments.dropFirst().first {
        return URL(fileURLWithPath: namedPath, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("CompactionRecording-\(ULID().ulidString)", isDirectory: true)
}()

// The tool never writes into a directory that already exists — least of all
// the checked-in fixture. A person copies the output in deliberately.
if FileManager.default.fileExists(atPath: outputDirectory.path) {
    fail(
        """
        \(outputDirectory.path) already exists. This tool refuses to overwrite anything: \
        name a directory that does not exist yet, or let the tool make a fresh one.
        """)
}
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("cannot create \(outputDirectory.path): \(error)")
}

print("[record] output: \(outputDirectory.path)")
print("[record] model: \(RecordingScript.recordingModel.stringValue) at context \(RecordingScript.workingContextTokens)")
print("[record] decoding: argmax, reply ceiling \(RecordingScript.replyTokenCeiling) tokens per turn")

// MARK: - Record the conversation

// The router writes the raw layout `<raw>/<routerId>/<sessionId>/...`; the
// finished output flattens the router segment away below, matching the shape
// the fixture directory plays.
let rawRecordingsDirectory = outputDirectory.appendingPathComponent("raw", isDirectory: true)

// Argmax decoding, pinned at the loader so every generation of the run is
// repeatable: the provider default samples from MLX's process-global PRNG,
// which seeds itself from the clock.
let router = Router(
    recordingsDir: rawRecordingsDirectory,
    loader: LiveModelLoader(
        downloader: #hubDownloader(),
        tokenizerLoader: #huggingFaceTokenizerLoader(),
        samplingMode: .greedy
    )
)

let definition = ProfileDefinition(
    name: "compaction-fixture-recording",
    description: "One real 30B model, recorded through six scripted turns to refresh the checked-in compaction fixture.",
    standard: [RecordingScript.recordingModel],
    flash: [RecordingScript.recordingModel],
    embedding: [RecordingScript.embeddingModel],
    context: RecordingScript.workingContextTokens
)

// `progress.phases` yields each phase transition as one element and ends at
// ready/failed, so the long resolve (a download on first run) stays visible.
let progress = ResolutionProgress()
let progressTask = Task { @MainActor in
    for await transition in progress.phases {
        let percent = Int((transition.fraction * 100).rounded())
        print("[resolve] phase=\(transition.phase) fraction=\(percent)%")
    }
}

let profile: LanguageModelProfile
do {
    profile = try await router.resolve(profile: definition, reporting: progress)
} catch {
    fail("could not resolve \(RecordingScript.recordingModel.stringValue): \(error)")
}
await progressTask.value

// Redaction setting 1: `workingDirectory` is the synthetic fixture value.
// Redaction setting 2: `recordingRoot:` stays unset — the router-level layout
// above is used, because a per-session recording root is stamped into
// `session.json` as an absolute machine path (the `^pfdrppj` leak). See
// `RecordingScript.fixtureWorkingDirectory`.
let session = profile.standard.makeSession(
    instructions: RecordingScript.instructions,
    workingDirectory: RecordingScript.fixtureWorkingDirectory,
    tools: RecordingScript.tools
)

let recordingStartedAt = Date()
for (index, prompt) in RecordingScript.prompts.enumerated() {
    do {
        let reply = try await session.respond(to: prompt, maxTokens: RecordingScript.replyTokenCeiling)
        print("[turn \(index + 1)/\(RecordingScript.prompts.count)] replied with \(reply.count) characters")
    } catch {
        fail("turn \(index + 1) failed: \(error)")
    }
}
print("[record] \(String(format: "%.0f", Date().timeIntervalSince(recordingStartedAt))) s of recording wall clock")

await profile.release()

// MARK: - Flatten the layout to the fixture's shape

// The fixture directory plays the recording root, with the session directly
// under it. Move `<raw>/<routerId>/<sessionId>` up to the output directory
// and drop `raw`, so the output mirrors the fixture byte for byte. The
// router id is not lost: `session.json` carries it as `routerId`.
let routerDirectory = onlySubdirectory(of: rawRecordingsDirectory, holding: "router directory")
let rawSessionDirectory = onlySubdirectory(of: routerDirectory, holding: "session directory")
let sessionDirectory = outputDirectory.appendingPathComponent(
    rawSessionDirectory.lastPathComponent, isDirectory: true)
do {
    try FileManager.default.moveItem(at: rawSessionDirectory, to: sessionDirectory)
    try FileManager.default.removeItem(at: rawRecordingsDirectory)
} catch {
    fail("could not flatten the recorded layout: \(error)")
}

// MARK: - Verify the recording reads back with the shape real traffic has

let transcript: Transcript
do {
    let tree = try TranscriptTree.load(under: outputDirectory)
    guard let root = tree.roots.first else {
        fail("the finished recording at \(outputDirectory.path) holds no session")
    }
    transcript = try tree.effectiveTranscript(forSession: root.id, view: .fullHistory)
} catch {
    fail("the finished recording does not read back: \(error)")
}

let kinds = TranscriptEntryKinds.names(of: transcript)
let missingKinds = TranscriptEntryKinds.realTrafficKinds.filter { !kinds.contains($0) }
guard missingKinds.isEmpty else {
    fail(
        """
        the recording carries no \(missingKinds.joined(separator: ", ")) entry — it holds \(kinds). \
        A recording without every real-traffic kind fails the integration suite; record again, \
        and check the model really answered and called its tools.
        """)
}
print(
    "[verify] \(Array(transcript).count) entries, kinds \(kinds), "
        + "\(Compactor.estimatedTokenCount(of: transcript)) estimated tokens")

// MARK: - The redaction scan, over the recorded bytes

// The fixed patterns plus this machine's own identity: user name, home,
// temporary directory, and the working directory the tool runs in.
let redactionPatterns = RecordingRedactionScan.operatorPatterns + RecordingRedactionScan.machinePatterns()
var redactionFindings: [RecordingRedactionScan.Finding] = []
for fileURL in recordedFiles(under: outputDirectory) {
    guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
        fail("cannot read \(fileURL.path) back for the redaction scan")
    }
    redactionFindings += RecordingRedactionScan.findings(
        in: text, file: fileURL.lastPathComponent, patterns: redactionPatterns)
}
guard redactionFindings.isEmpty else {
    for finding in redactionFindings {
        FileHandle.standardError.write(Data("[redaction] \(finding)\n".utf8))
    }
    fail(
        """
        the recording carries the \(redactionFindings.count) forbidden pattern hit(s) above and must \
        not be committed. Read each named line under \(sessionDirectory.path); fix the cause at \
        record time (never by editing the recording) and run the tool again.
        """)
}
print("[verify] redaction scan clean over \(redactionPatterns.count) patterns")

// MARK: - Hand over

print(
    """
    [done] the recording is verified and clean, at:
        \(sessionDirectory.path)
    To replace the checked-in fixture:
      1. Delete the old session directory (NOT README.md) under
         Tests/FoundationModelsRouterRealModelSupport/Fixtures/CompactionRecording/.
      2. Copy the directory above into Fixtures/CompactionRecording/.
      3. Run: swift test --filter 'RecordedTranscriptCompaction|RecordedFixtureRedaction'
    """)
